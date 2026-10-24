package app

import "core:fmt"
import "core:strings"
import "core:time"

// The labels of a channel's video page's buttons, one per kind of video.
@(rodata)
VIDEO_KIND_LABELS := [Video_Kind]string {
	.Broadcast = "Past broadcasts",
	.Highlight = "Highlights",
	.Upload    = "Uploads",
	.Clip      = "Clips",
}

// What one of each kind of video is called.
@(rodata)
VIDEO_KIND_NAMES := [Video_Kind]string {
	.Broadcast = "Past broadcast",
	.Highlight = "Highlight",
	.Upload    = "Upload",
	.Clip      = "Clip",
}

// One kind of a channel's videos, a page at a time.
Video_List :: struct {
	state:   Browse_State,
	// Owned.
	videos:  [dynamic]Vod,
	// The cursor for the next page ("" at the end), and whether it's being fetched.
	next:    string,
	loading: bool,
}

// A channel's video page: its past broadcasts, highlights, uploads and clips.
Channel_Videos :: struct {
	// The channel (owned), and which kind of video is shown.
	login, name: string,
	kind:        Video_Kind,
	lists:       [Video_Kind]Video_List,
	// Where Esc and the back button go.
	back_view:   Browse_View,
	// From the last draw, in pixels.
	kind_buttons: [Video_Kind]Rect,
	chat_button:  Rect,
}

channel_videos_destroy :: proc(app: ^App, v: ^Channel_Videos) {
	for &l in v.lists {
		video_list_clear(app, &l)
		delete(l.videos)
	}
	delete(v.login)
	delete(v.name)
}

// Forgets a list's videos, releasing their thumbnails.
@(private = "file")
video_list_clear :: proc(app: ^App, l: ^Video_List) {
	for v in l.videos {
		if v.thumbnail_url != "" && app != nil {
			image_release(&app.assets.images, v.thumbnail_url)
		}
		destroy_vod(v)
	}
	clear(&l.videos)
	delete(l.next)
	l.next = ""
	l.state = .Empty
	l.loading = false
}

// Opens `login`'s video page on its past broadcasts. `name` is how to show the
// channel ("" for the login).
browse_open_videos :: proc(app: ^App, login, name: string) {
	b := &app.browse
	v := &b.videos
	if login != v.login {
		for &l in v.lists {
			video_list_clear(app, &l)
		}
		delete(v.login)
		delete(v.name)
		v.login = strings.clone(login)
		v.name = strings.clone(name if name != "" else login)
		v.kind = .Broadcast
		b.scroll[.Videos] = 0
	}
	if b.view != .Videos {
		v.back_view = b.view
	}
	if b.view == .Search {
		browse_search_unfocus(app)
	}
	b.view = .Videos
	b.hovered = -1
}

// Fetches the shown list again from its first page (R).
videos_refresh :: proc(app: ^App) {
	v := &app.browse.videos
	if !v.lists[v.kind].loading {
		video_list_clear(app, &v.lists[v.kind])
		app.browse.scroll[.Videos] = 0
	}
}

// Back to where the video page was opened from.
videos_back :: proc(app: ^App) {
	b := &app.browse
	b.view = b.videos.back_view if b.videos.back_view != .Videos else .Following
	b.hovered = -1
}

// Fetches the shown list's first page when it has none. Returns -1: nothing is
// due later.
videos_tick :: proc(app: ^App) -> int {
	v := &app.browse.videos
	l := &v.lists[v.kind]
	if l.state == .Empty && !l.loading {
		videos_fetch(app, v.kind, "")
	}
	return -1
}

Videos_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	login:     string,
	kind:      Video_Kind,
	cursor:    string,
	check:     Auth_Check,
	ok:        bool,
	// Owned.
	videos:    [dynamic]Vod,
	next:      string,
}

destroy_videos_job :: proc(p: ^Videos_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.login)
	delete(p.cursor)
	for v in p.videos {
		destroy_vod(v)
	}
	delete(p.videos)
	delete(p.next)
}

@(private = "file")
videos_fetch :: proc(app: ^App, kind: Video_Kind, cursor: string) {
	v := &app.browse.videos
	l := &v.lists[kind]
	l.loading = true
	if cursor == "" {
		l.state = .Loading
	}
	jobs_add(
		&app.assets.jobs,
		run_videos_job,
		Videos_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth) if app.signed_in else {},
			login = strings.clone(v.login),
			kind = kind,
			cursor = strings.clone(cursor),
		},
	)
}

@(private = "file")
run_videos_job :: proc(job: ^Job) {
	p := &job.payload.(Videos_Job)
	p.check = .Valid
	videos, next, err := get_channel_videos(p.client_id, p.auth.access_token, p.login, p.kind, p.cursor)
	if err == .Unauthorized && p.auth.refresh_token != "" {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		videos, next, err = get_channel_videos(p.client_id, p.auth.access_token, p.login, p.kind, p.cursor)
	}
	if err != .None {
		return
	}
	p.ok = true
	for video in videos {
		append(&p.videos, clone_vod(video))
	}
	p.next = strings.clone(next)
}

// Adds a page to its list, unless the page shows another channel by now.
finish_videos_job :: proc(app: ^App, p: ^Videos_Job) {
	if p.auth.access_token != "" {
		apply_auth_check(app, p.check, p.auth)
	}
	v := &app.browse.videos
	if p.login != v.login {
		return
	}
	l := &v.lists[p.kind]
	l.loading = false
	if !p.ok {
		if p.cursor == "" {
			l.state = .Failed
		}
		// A later page that failed isn't tried again until the list is reopened.
		delete(l.next)
		l.next = ""
		return
	}
	append(&l.videos, ..p.videos[:])
	clear(&p.videos)
	delete(l.next)
	l.next, p.next = p.next, ""
	l.state = .Loaded
}

// A click on the page's buttons or one of its videos. Returns true if it hit one.
videos_click :: proc(app: ^App, x, y: f32, card: int) -> bool {
	b := &app.browse
	v := &b.videos
	for button, kind in v.kind_buttons {
		if button.w > 0 && in_rect(button, x, y) {
			v.kind = kind
			b.scroll[.Videos] = 0
			b.hovered = -1
			return true
		}
	}
	if v.chat_button.w > 0 && in_rect(v.chat_button, x, y) {
		watch_start(app, v.login)
		return true
	}
	l := &v.lists[v.kind]
	if card >= 0 && card < len(l.videos) {
		watch_start_vod(app, l.videos[card])
		return true
	}
	return false
}

// "2:05:09 · 3 days ago · 117K views", for a card.
@(private = "file")
video_details :: proc(video: Vod, now: time.Time) -> string {
	ago := format_last_live(video.created_at, now)
	ago = strings.to_lower(ago[len("Live "):], context.temp_allocator) if strings.has_prefix(ago, "Live ") else ""
	parts := make([dynamic]string, context.temp_allocator)
	if ago != "" {
		append(&parts, ago)
	}
	append(&parts, fmt.tprintf("%s views", format_viewers(video.views)))
	return strings.join(parts[:], "  ·  ", context.temp_allocator)
}

// The page: a heading with the back and Chat buttons, a button per kind of video,
// then the shown kind as cards. More are fetched once scrolling nears the end.
draw_videos :: proc(app: ^App, content: Rect) {
	a := &app.assets
	r := &a.renderer
	b := &app.browse
	v := &b.videos
	scale := app.scale
	pad := BROWSE_PADDING * scale
	gap := BROWSE_GAP * scale
	tab_size := BROWSE_TAB_SIZE * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	lh := line_height(r, .Bold, tab_size)
	lh_text := line_height(r, .Regular, text_size)
	heading_h := lh + pad
	y := content.y + pad / 2 + (heading_h - lh) / 2

	// The heading: back, the channel's name, and a button to open its chat.
	b.back_button = {content.x + pad / 2, content.y + pad / 2, 36 * scale * r.text_scale, heading_h}
	if in_rect(b.back_button, app.mouse.x, app.mouse.y) {
		draw_rect(r, b.back_button, BROWSE_CARD_HOVER)
	}
	draw_centered(r, .Bold, tab_size * 1.6, b.back_button, "‹", BROWSE_TEXT)
	x := draw_text(r, .Bold, tab_size, b.back_button.x + b.back_button.w + 8 * scale, y, v.name, BROWSE_TEXT)
	chat_label := "Chat"
	bw := text_width(r, .Bold, text_size, chat_label) + 24 * scale
	bh := lh_text + 12 * scale
	v.chat_button = {x + 16 * scale, y + (lh - bh) / 2, bw, bh}
	draw_rect(r, v.chat_button, BROWSE_CARD_HOVER if in_rect(v.chat_button, app.mouse.x, app.mouse.y) else BROWSE_PLACEHOLDER)
	draw_centered(r, .Bold, text_size, v.chat_button, chat_label, BROWSE_TEXT)

	// A button per kind of video, like the Categories tab's sections.
	button_y := content.y + pad / 2 + heading_h + pad / 2
	bx := content.x + pad
	for kind in Video_Kind {
		label := VIDEO_KIND_LABELS[kind]
		button := Rect{bx, button_y, text_width(r, .Bold, text_size, label) + 24 * scale, bh}
		v.kind_buttons[kind] = button
		shown := kind == v.kind
		hovered := in_rect(button, app.mouse.x, app.mouse.y)
		draw_rect(r, button, BROWSE_ACCENT if shown else (BROWSE_CARD_HOVER if hovered else BROWSE_PLACEHOLDER))
		draw_centered(r, .Bold, text_size, button, label, BROWSE_BACKGROUND if shown else BROWSE_TEXT)
		bx += button.w + 8 * scale
	}

	list := Rect{content.x, button_y + bh, content.w, content.y + content.h - button_y - bh}
	l := &v.lists[v.kind]
	message := ""
	switch {
	case l.state == .Empty || (l.state == .Loading && len(l.videos) == 0):
		message = "Loading..."
	case l.state == .Failed:
		message = "Couldn't load the videos. Press R to try again."
	case len(l.videos) == 0:
		message = fmt.tprintf("%s has no %s.", v.name, strings.to_lower(VIDEO_KIND_LABELS[v.kind], context.temp_allocator))
	}
	if message != "" {
		draw_centered(r, .Regular, text_size, list, message, BROWSE_DIM_TEXT)
		return
	}

	min_w := BROWSE_CARD_WIDTH * scale
	columns := max(1, int((list.w - 2 * pad + gap) / (min_w + gap)))
	card_w := (list.w - 2 * pad - gap * f32(columns - 1)) / f32(columns)
	thumb_h := card_w * 9 / 16
	card_title_size := BROWSE_CARD_TITLE_SIZE * scale
	lh_title := line_height(r, .Bold, card_title_size)
	text_pad := 8 * scale
	card_h := thumb_h + text_pad + lh_title + 2 * lh_text + text_pad
	rows := (len(l.videos) + columns - 1) / columns
	total_h := f32(rows) * card_h + f32(max(rows - 1, 0)) * gap + 2 * pad
	scroll := &b.scroll[.Videos]
	b.max_scroll[.Videos] = max(0, total_h - list.h)
	scroll^ = min(scroll^, b.max_scroll[.Videos])
	// The next page, once the end is near.
	if l.next != "" && !l.loading && scroll^ > b.max_scroll[.Videos] - list.h {
		videos_fetch(app, v.kind, l.next)
	}

	tooltip: Rect
	tooltip_title: string
	now := time.now()
	clip_begin(r, list)
	for video, i in l.videos {
		card := Rect {
			list.x + pad + f32(i % columns) * (card_w + gap),
			list.y + pad + f32(i / columns) * (card_h + gap) - scroll^,
			card_w,
			card_h,
		}
		append(&b.cards, card)
		if card.y > list.y + list.h || card.y + card.h < list.y {
			continue
		}
		if i == b.hovered {
			draw_rect(r, card, BROWSE_CARD_HOVER)
		}
		thumb := Rect{card.x, card.y, card.w, thumb_h}
		image := image_get(&a.images, &a.jobs, video.thumbnail_url, 1) if video.thumbnail_url != "" else nil
		if image != nil && image.state == .Ready {
			texture, _ := image_frame(image, a.now_ms)
			draw_image(r, texture, thumb)
		} else {
			draw_rect(r, thumb, BROWSE_PLACEHOLDER)
		}

		// The length over the thumbnail's bottom left, or that it's live.
		inset := 6 * scale
		badge_text := "LIVE" if video.recording else format_clock(video.length)
		badge := Rect{thumb.x + inset, thumb.y + thumb.h - inset - lh_text - 4 * scale, text_width(r, .Regular, text_size, badge_text) + 12 * scale, lh_text + 4 * scale}
		draw_rect(r, badge, LIVE_RED if video.recording else VIEWERS_BACKGROUND)
		draw_text(r, .Regular, text_size, badge.x + 6 * scale, badge.y + 2 * scale, badge_text, BROWSE_TEXT)

		tx := card.x + text_pad
		tw := card.w - 2 * text_pad
		ty := thumb.y + thumb.h + text_pad
		if _, cut := draw_text_line(a, .Bold, card_title_size, tx, ty, video.title, BROWSE_TEXT, tw); cut && i == b.hovered {
			tooltip, tooltip_title = {tx, ty, tw, card.y + card.h - ty}, video.title
		}
		ty += lh_title
		draw_text(r, .Regular, text_size, tx, ty, fit_text(r, .Regular, text_size, video_details(video, now), tw), BROWSE_DIM_TEXT)
		ty += lh_text
		draw_text(r, .Regular, text_size, tx, ty, fit_text(r, .Regular, text_size, video.game, tw), BROWSE_ACCENT)
	}
	clip_end(r)
	draw_title_tooltip(app, tooltip, tooltip_title, list, .Bold, card_title_size, text_pad)
}
