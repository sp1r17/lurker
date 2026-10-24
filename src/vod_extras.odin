package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

// The playback speeds [ and ] step through.
@(rodata)
VOD_SPEEDS := [?]f64{0.5, 0.75, 1, 1.25, 1.5, 1.75, 2}

// A past broadcast's preview frames: sheets of `cols` by `rows` frames, one every
// `interval` seconds, from Twitch's storyboard.
Storyboard :: struct {
	interval:      f64,
	width, height: int,
	cols, rows:    int,
	// The sheets' full addresses, in order. Owned.
	sheets:        [dynamic]string,
}

storyboard_destroy :: proc(s: ^Storyboard) {
	for url in s.sheets {
		delete(url)
	}
	delete(s.sheets)
	s^ = {}
}

// A storyboard's info file (from `info_url`): its larger frames if there are any.
parse_storyboard :: proc(body: []byte, info_url: string) -> (s: Storyboard, ok: bool) {
	Entry :: struct {
		quality:       string,
		interval:      f64,
		width, height: int,
		cols, rows:    int,
		images:        []string,
	}
	entries: []Entry
	if json.unmarshal(body, &entries, allocator = context.temp_allocator) != nil || len(entries) == 0 {
		return {}, false
	}
	best := entries[0]
	for e in entries {
		if e.quality == "high" {
			best = e
		}
	}
	if best.interval <= 0 || best.cols <= 0 || best.rows <= 0 || len(best.images) == 0 {
		return {}, false
	}
	base := info_url[:strings.last_index_byte(info_url, '/') + 1]
	s = {interval = best.interval, width = best.width, height = best.height, cols = best.cols, rows = best.rows}
	for image in best.images {
		append(&s.sheets, strings.concatenate({base, image}))
	}
	return s, true
}

// Which sheet holds the frame for `seconds`, and where in it, as texture
// coordinates (u0, v0, u1, v1).
storyboard_frame :: proc(s: ^Storyboard, seconds: f64) -> (sheet: int, uv: [4]f32, ok: bool) {
	if len(s.sheets) == 0 {
		return
	}
	per_sheet := s.cols * s.rows
	frame := max(int(seconds / s.interval), 0)
	sheet = min(frame / per_sheet, len(s.sheets) - 1)
	within := frame - sheet * per_sheet
	if within >= per_sheet {
		within = per_sheet - 1
	}
	col, row := within % s.cols, within / s.cols
	uv = {f32(col) / f32(s.cols), f32(row) / f32(s.rows), f32(col + 1) / f32(s.cols), f32(row + 1) / f32(s.rows)}
	return sheet, uv, true
}

// The chapter playing at `ms`, or -1 before the first.
chapter_at :: proc(chapters: []Chapter, ms: int) -> int {
	found := -1
	for c, i in chapters {
		if c.start <= ms {
			found = i
		}
	}
	return found
}

// Looks up a past broadcast's chapters and storyboard, once it's playing.
Vod_Extras_Job :: struct {
	client_id:    string,
	// A copy, empty when signed out.
	auth:         Auth,
	vod_id:       string,
	previews_url: string,
	session:      int,
	// Owned (with the chapters' titles).
	chapters:     [dynamic]Chapter,
	storyboard:   Storyboard,
}

destroy_vod_extras_job :: proc(p: ^Vod_Extras_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.vod_id)
	delete(p.previews_url)
	chapters_destroy(&p.chapters)
	storyboard_destroy(&p.storyboard)
}

chapters_destroy :: proc(chapters: ^[dynamic]Chapter) {
	for c in chapters {
		delete(c.title)
	}
	delete(chapters^)
	chapters^ = nil
}

// Fetches the chapters and storyboard of the video playing, unless they're its
// already. Clips have neither.
vod_extras_request :: proc(app: ^App) {
	w := &app.watch
	if w.vod.kind == .Clip || w.extras_id == w.vod.id {
		return
	}
	chapters_destroy(&w.chapters)
	storyboard_destroy(&w.storyboard)
	delete(w.extras_id)
	w.extras_id = strings.clone(w.vod.id)
	jobs_add(
		&app.assets.jobs,
		run_vod_extras_job,
		Vod_Extras_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth) if app.signed_in else {},
			vod_id = strings.clone(w.vod.id),
			previews_url = strings.clone(w.vod.seek_previews_url),
			session = app.session,
		},
	)
}

@(private = "file")
run_vod_extras_job :: proc(job: ^Job) {
	p := &job.payload.(Vod_Extras_Job)
	if chapters, err := get_chapters(p.client_id, p.auth.access_token, p.vod_id); err == .None {
		for c in chapters {
			append(&p.chapters, Chapter{c.start, c.length, strings.clone(c.title)})
		}
	}
	if p.previews_url != "" {
		if res, ok := http_request(p.previews_url, allocator = context.temp_allocator); ok && res.status == 200 {
			p.storyboard, _ = parse_storyboard(res.body, p.previews_url)
		}
	}
}

finish_vod_extras_job :: proc(app: ^App, p: ^Vod_Extras_Job) {
	w := &app.watch
	if app.screen != .Watch || p.session != app.session || p.vod_id != w.extras_id {
		return
	}
	chapters_destroy(&w.chapters)
	w.chapters, p.chapters = p.chapters, nil
	storyboard_destroy(&w.storyboard)
	w.storyboard, p.storyboard = p.storyboard, {}
}

// Forgets the chapters and storyboard (leaving the watch).
vod_extras_clear :: proc(w: ^Watch) {
	chapters_destroy(&w.chapters)
	storyboard_destroy(&w.storyboard)
	delete(w.extras_id)
	w.extras_id = ""
}

// Sets the playback speed, one of VOD_SPEEDS.
vod_set_speed :: proc(app: ^App, speed: f64) {
	app.watch.speed = speed
	player_command(&app.player, {"set", "speed", fmt.ctprintf("%.2f", speed)})
	app.watch.controls_until = app.assets.now_ms + CONTROLS_MS
}

// One step faster (`by` 1) or slower (-1), within VOD_SPEEDS.
vod_speed_step :: proc(app: ^App, by: int) {
	i := 2
	for s, j in VOD_SPEEDS {
		if s == app.watch.speed {
			i = j
		}
	}
	vod_set_speed(app, VOD_SPEEDS[clamp(i + by, 0, len(VOD_SPEEDS) - 1)])
}

// Seeks to the next chapter (`by` 1) or the start of this one, or the one before
// if it's just begun (-1).
vod_chapter_step :: proc(app: ^App, by: int) {
	w := &app.watch
	if len(w.chapters) == 0 {
		return
	}
	pos, _ := player_number(&app.player, "time-pos")
	ms := int(pos * 1000)
	i := chapter_at(w.chapters[:], ms)
	target := 0
	if by > 0 {
		target = i + 1
		if target >= len(w.chapters) {
			return
		}
	} else {
		target = max(i, 0)
		// Within a few seconds of its start, the one before.
		if i >= 0 && ms - w.chapters[i].start < 3000 {
			target = max(i - 1, 0)
		}
	}
	vod_seek(app, f64(w.chapters[target].start) / 1000)
}

vod_seek :: proc(app: ^App, seconds: f64) {
	player_command(&app.player, {"seek", fmt.ctprintf("%.1f", seconds), "absolute"})
	app.watch.controls_until = app.assets.now_ms + CONTROLS_MS
}

// Keys for the extras: [ and ] for speed, Page Up and Page Down for chapters.
// Returns true if the key was one.
vod_extras_key :: proc(app: ^App, key: sdl.KeyboardEvent) -> bool {
	switch key.key {
	case sdl.K_LEFTBRACKET:
		vod_speed_step(app, -1)
	case sdl.K_RIGHTBRACKET:
		vod_speed_step(app, 1)
	case sdl.K_PAGEUP:
		vod_chapter_step(app, -1)
	case sdl.K_PAGEDOWN:
		vod_chapter_step(app, 1)
	case:
		return false
	}
	return true
}

// The Chapters button, with its right edge at `right` on the seek bar's row
// (`row`); returns its left edge, or `right` without chapters.
draw_chapters_button :: proc(app: ^App, right: f32, row: Rect) -> f32 {
	w := &app.watch
	w.chapters_button = {}
	if len(w.chapters) < 2 {
		w.chapter_menu = false
		return right
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	label := "Chapters"
	bw := text_width(r, .Bold, size, label) + 24 * scale
	w.chapters_button = {right - bw, row.y, bw, row.h}
	hovered := in_rect(w.chapters_button, app.mouse.x, app.mouse.y)
	draw_rect(r, w.chapters_button, MENU_HOVER if hovered || w.chapter_menu else CHAT_TOGGLE_BACKGROUND)
	draw_centered(r, .Bold, size, w.chapters_button, label, BROWSE_TEXT)
	return w.chapters_button.x
}

// The open chapter list, above its button: each chapter's start and title, the
// one playing ticked.
draw_chapter_menu :: proc(app: ^App) {
	w := &app.watch
	clear(&w.chapter_items)
	if !w.chapter_menu || w.chapters_button.w == 0 {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	item_h := MENU_ITEM_HEIGHT * scale * r.text_scale
	pos, _ := player_number(&app.player, "time-pos")
	playing := chapter_at(w.chapters[:], int(pos * 1000))
	labels := make([]string, len(w.chapters), context.temp_allocator)
	menu_w := w.chapters_button.w
	for c, i in w.chapters {
		labels[i] = fmt.tprintf("%s   %s", format_clock(c.start / 1000), c.title)
		menu_w = max(menu_w, text_width(r, .Bold, size, labels[i]) + 70 * scale)
	}
	menu_w = min(menu_w, w.video_rect.w - 32 * scale)
	// As many as fit above the button; the rest are reached with Page Up/Down.
	shown := min(len(w.chapters), max(1, int((w.chapters_button.y - w.video_rect.y - 16 * scale) / item_h)))
	menu_h := item_h * f32(shown)
	menu := Rect{w.chapters_button.x + w.chapters_button.w - menu_w, w.chapters_button.y - 6 * scale - menu_h, menu_w, menu_h}
	draw_rect(r, menu, USER_CARD_BACKGROUND)
	for i in 0 ..< shown {
		item := Rect{menu.x, menu.y + f32(i) * item_h, menu.w, item_h}
		append(&w.chapter_items, item)
		draw_menu_item(app, item, fit_text(r, .Bold, size, labels[i], menu.w - 50 * scale), i == playing)
	}
}

// A click on the chapter list or its button. Returns true if it was one.
chapter_menu_click :: proc(app: ^App, x, y: f32) -> bool {
	w := &app.watch
	for item, i in w.chapter_items {
		if in_rect(item, x, y) && i < len(w.chapters) {
			w.chapter_menu = false
			vod_seek(app, f64(w.chapters[i].start) / 1000)
			return true
		}
	}
	if w.chapters_button.w > 0 && in_rect(w.chapters_button, x, y) {
		w.chapter_menu = !w.chapter_menu
		return true
	}
	return false
}

// Over the seek bar: where a click would go, as a frame from the storyboard with
// its time and chapter, above the bar at the mouse.
draw_seek_preview :: proc(app: ^App, track: Rect, duration: f64) {
	w := &app.watch
	if !in_rect(w.seek_bar, app.mouse.x, app.mouse.y) {
		return
	}
	a := &app.assets
	r := &a.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	lh := line_height(r, .Bold, size)
	pad := 6 * scale
	at := f64(clamp((app.mouse.x - track.x) / track.w, 0, 1)) * duration
	label := format_clock(int(at))
	if i := chapter_at(w.chapters[:], int(at * 1000)); i >= 0 {
		label = fmt.tprintf("%s  ·  %s", label, w.chapters[i].title)
	}

	frame_w, frame_h: f32
	sheet, uv, has_frame := storyboard_frame(&w.storyboard, at)
	if has_frame && w.storyboard.width > 0 {
		frame_w = f32(w.storyboard.width) * scale * r.text_scale
		frame_h = f32(w.storyboard.height) * scale * r.text_scale
	}
	label_w := min(text_width(r, .Bold, size, label), w.video_rect.w / 2)
	box_w := max(frame_w, label_w) + 2 * pad
	box_h := frame_h + lh + 2 * pad + (pad if frame_h > 0 else 0)
	box := Rect{app.mouse.x - box_w / 2, track.y - 12 * scale - box_h, box_w, box_h}
	box.x = clamp(box.x, w.video_rect.x, w.video_rect.x + w.video_rect.w - box.w)
	draw_rect(r, box, USER_CARD_BACKGROUND)
	if frame_h > 0 {
		frame := Rect{box.x + (box.w - frame_w) / 2, box.y + pad, frame_w, frame_h}
		image := image_get(&a.images, &a.jobs, w.storyboard.sheets[sheet], 1, cache = false)
		if image.state == .Ready {
			texture, _ := image_frame(image, a.now_ms)
			draw_image_part(r, texture, frame, uv)
		} else {
			draw_rect(r, frame, BROWSE_PLACEHOLDER)
		}
	}
	label = fit_text(r, .Bold, size, label, box.w - 2 * pad)
	draw_text(r, .Bold, size, box.x + (box.w - text_width(r, .Bold, size, label)) / 2, box.y + box.h - pad - lh, label, BROWSE_TEXT)
}

// Marks on the seek bar's track where each chapter after the first begins.
draw_chapter_marks :: proc(app: ^App, track: Rect, duration: f64) {
	w := &app.watch
	r := &app.assets.renderer
	scale := app.scale
	for c in w.chapters {
		if c.start <= 0 {
			continue
		}
		x := track.x + track.w * f32(f64(c.start) / 1000 / duration)
		draw_rect(r, {x - scale, track.y - 2 * scale, 2 * scale, track.h + 4 * scale}, BROWSE_TEXT)
	}
}
