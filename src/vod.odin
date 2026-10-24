package app

import "core:fmt"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

// How far Left and Right seek in a past broadcast.
VOD_SEEK_SECONDS :: 10
VOD_BAR_HEIGHT :: 6

Vod_State :: enum {
	// Not looked up: the channel is live, or hasn't said yet.
	None,
	Loading,
	Found,
	Missing,
}

// Looks up a channel's latest past broadcast.
Vod_Job :: struct {
	client_id: string,
	// A copy, empty when signed out; the job may refresh it.
	auth:      Auth,
	login:     string,
	// The watch it's for; dropped if that's over.
	session:   int,
	check:     Auth_Check,
	ok, found: bool,
	// Owned, if found.
	vod:       Vod,
}

destroy_vod_job :: proc(p: ^Vod_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.login)
	destroy_vod(p.vod)
}

// Finds the address of a past broadcast's video, with streamlink.
Vod_Url_Job :: struct {
	vod_id:    string,
	kind:      Video_Kind,
	quality:   Quality,
	client_id: string,
	token:     string,
	// Where to start, in seconds.
	start:     f64,
	session:   int,
	// Owned, if found.
	url:       string,
	ok:        bool,
}

destroy_vod_url_job :: proc(p: ^Vod_Url_Job) {
	delete(p.vod_id)
	delete(p.client_id)
	delete(p.token)
	delete(p.url)
}

// Once the channel turns out to be offline (or its stream ends): looks up its
// last broadcast, to offer it.
vod_lookup :: proc(app: ^App) {
	w := &app.watch
	if w.vod_state != .None {
		return
	}
	w.vod_state = .Loading
	jobs_add(
		&app.assets.jobs,
		run_vod_job,
		Vod_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth) if app.signed_in else {},
			login = strings.clone(w.channel),
			session = app.session,
		},
	)
}

@(private = "file")
run_vod_job :: proc(job: ^Job) {
	p := &job.payload.(Vod_Job)
	p.check = .Valid
	vod, found, err := get_latest_vod(p.client_id, p.auth.access_token, p.login)
	if err == .Unauthorized && p.auth.refresh_token != "" {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		vod, found, err = get_latest_vod(p.client_id, p.auth.access_token, p.login)
	}
	p.ok = err == .None
	if p.ok && found {
		p.found = true
		p.vod = clone_vod(vod)
	}
}

finish_vod_job :: proc(app: ^App, p: ^Vod_Job) {
	if p.auth.access_token != "" {
		apply_auth_check(app, p.check, p.auth)
	}
	w := &app.watch
	if app.screen != .Watch || p.session != app.session {
		return
	}
	if !p.found {
		w.vod_state = .Missing
		return
	}
	destroy_vod(w.vod)
	w.vod, p.vod = p.vod, {}
	w.vod_state = .Found
}

// Plays the channel's last broadcast, from `start` seconds in.
watch_play_vod :: proc(app: ^App, start: f64 = 0) {
	w := &app.watch
	if w.vod_state != .Found {
		return
	}
	player_command(&app.player, {"stop"})
	streamlink_stop(&w.streamlink)
	player_clear(&app.player)
	w.status = .Starting
	w.ended_at = 0
	w.playing_vod = true
	w.vod_pending = true
	job := Vod_Url_Job {
		vod_id  = strings.clone(w.vod.id),
		kind    = w.vod.kind,
		quality = app.layout.quality,
		start   = start,
		session = app.session,
	}
	if app.signed_in {
		job.client_id = strings.clone(app.client_id)
		job.token = strings.clone(app.auth.access_token)
	}
	jobs_add(&app.assets.jobs, run_vod_url_job, job)
}

@(private = "file")
run_vod_url_job :: proc(job: ^Job) {
	p := &job.payload.(Vod_Url_Job)
	p.url, p.ok = streamlink_vod_url(p.vod_id, p.kind, p.quality, p.client_id, p.token)
}

finish_vod_url_job :: proc(app: ^App, p: ^Vod_Url_Job) {
	w := &app.watch
	if app.screen != .Watch || p.session != app.session || !w.playing_vod {
		return
	}
	w.vod_pending = false
	if !p.ok {
		w.status = .Failed
		return
	}
	player_load_at(&app.player, p.url, p.start)
	// Clips have no chat to replay.
	if w.vod.kind != .Clip {
		replay_start(app, p.start)
	}
}

// Watches `vod` (a video or clip) from `start` seconds in, with its channel's
// chat beside it.
watch_start_vod :: proc(app: ^App, vod: Vod, start: f64 = 0) {
	watch_start(app, vod.login, live = false)
	w := &app.watch
	destroy_vod(w.vod)
	w.vod = clone_vod(vod)
	w.vod_state = .Found
	watch_play_vod(app, start)
}

// Where the past broadcast is, in seconds, for picking it up again after a
// quality change.
vod_position :: proc(app: ^App) -> f64 {
	pos, _ := player_number(&app.player, "time-pos")
	return pos
}

// Left and Right seek while a past broadcast plays. Returns true if the key was used.
vod_key :: proc(app: ^App, key: sdl.KeyboardEvent) -> bool {
	w := &app.watch
	if !w.playing_vod || w.status != .Playing {
		return false
	}
	switch key.key {
	case sdl.K_LEFT:
		player_command(&app.player, {"seek", fmt.ctprintf("%d", -VOD_SEEK_SECONDS), "relative"})
	case sdl.K_RIGHT:
		player_command(&app.player, {"seek", fmt.ctprintf("%d", VOD_SEEK_SECONDS), "relative"})
	case:
		return false
	}
	w.controls_until = app.assets.now_ms + CONTROLS_MS
	return true
}

// A click on the offer to watch, or on the seek bar. Returns true if it was one.
vod_click :: proc(app: ^App, x, y: f32) -> bool {
	w := &app.watch
	if w.vod_button.w > 0 && in_rect(w.vod_button, x, y) {
		watch_play_vod(app)
		return true
	}
	if w.videos_button.w > 0 && in_rect(w.videos_button, x, y) {
		watch_open_videos(app, w.channel, w.info.user_name if w.has_info else "")
		return true
	}
	if w.seek_bar.w > 0 && in_rect(w.seek_bar, x, y) {
		if duration, ok := player_number(&app.player, "duration"); ok && duration > 0 {
			at := clamp((x - w.seek_bar.x) / w.seek_bar.w, 0, 1) * f32(duration)
			player_command(&app.player, {"seek", fmt.ctprintf("%.1f", at), "absolute"})
		}
		return true
	}
	return false
}

// "6:43:25" or "12:05".
format_clock :: proc(seconds: int) -> string {
	s := max(seconds, 0)
	if s >= 3600 {
		return fmt.tprintf("%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
	}
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// Under the offline (or ended) message: the video just watched or the last
// broadcast, with a button to watch it, and a button for all the channel's videos.
draw_vod_offer :: proc(app: ^App, video: Rect) {
	w := &app.watch
	w.vod_button = {}
	w.videos_button = {}
	if w.vod_state == .None || w.vod_state == .Loading {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	title_size := BROWSE_CARD_TITLE_SIZE * scale
	lh := line_height(r, .Regular, size)
	lh_title := line_height(r, .Bold, title_size)
	room := min(video.w - 64 * scale, 640 * scale * r.text_scale)
	cx := video.x + video.w / 2
	y := video.y + video.h / 2 + lh + 16 * scale

	found := w.vod_state == .Found
	if found {
		when_ := format_last_live(w.vod.created_at, time.now())
		detail := fmt.tprintf("%s · %s", when_, format_clock(w.vod.length))
		if w.vod.game != "" {
			detail = fmt.tprintf("%s · %s", detail, w.vod.game)
		}
		title := fit_text(r, .Bold, title_size, w.vod.title, room)
		draw_text(r, .Bold, title_size, cx - text_width(r, .Bold, title_size, title) / 2, y, title, BROWSE_TEXT)
		y += lh_title
		detail = fit_text(r, .Regular, size, detail, room)
		draw_text(r, .Regular, size, cx - text_width(r, .Regular, size, detail) / 2, y, detail, BROWSE_DIM_TEXT)
		y += lh + 12 * scale
	}

	// The buttons, side by side and centred.
	bh := lh + 16 * scale
	gap := 8 * scale
	watch_label := "Watch again (Enter)" if w.playing_vod else "Watch the last broadcast (Enter)"
	watch_w := text_width(r, .Bold, size, watch_label) + 32 * scale if found else 0
	videos_label := "All videos"
	videos_w := text_width(r, .Bold, size, videos_label) + 32 * scale
	x := cx - (watch_w + (gap if found else 0) + videos_w) / 2
	if found {
		w.vod_button = {x, y, watch_w, bh}
		hovered := in_rect(w.vod_button, app.mouse.x, app.mouse.y)
		draw_rect(r, w.vod_button, SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON)
		draw_centered(r, .Bold, size, w.vod_button, watch_label, BROWSE_TEXT)
		x += watch_w + gap
	}
	w.videos_button = {x, y, videos_w, bh}
	hovered := in_rect(w.videos_button, app.mouse.x, app.mouse.y)
	draw_rect(r, w.videos_button, BROWSE_CARD_HOVER if hovered else BROWSE_PLACEHOLDER)
	draw_centered(r, .Bold, size, w.videos_button, videos_label, BROWSE_TEXT)
}

// While a past broadcast plays, with the controls: a bar across the video's
// bottom showing where it is, which seeks when clicked, and the time.
draw_vod_seek :: proc(app: ^App, right: f32) {
	w := &app.watch
	w.seek_bar = {}
	if !w.playing_vod || w.status != .Playing || !controls_visible(app) {
		return
	}
	pos, has_pos := player_number(&app.player, "time-pos")
	duration, has_duration := player_number(&app.player, "duration")
	if !has_pos || !has_duration || duration <= 0 {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	lh := line_height(r, .Bold, size)
	v := w.video_rect
	pad := 16 * scale
	clock := fmt.tprintf("%s / %s", format_clock(int(pos)), format_clock(int(duration)))
	if player_paused(&app.player) {
		clock = fmt.tprintf("%s  ·  Paused", clock)
	}
	cw := text_width(r, .Bold, size, clock)
	panel := Rect{v.x + pad, v.y + v.h - pad - lh - 12 * scale, cw + 24 * scale, lh + 12 * scale}
	draw_rect(r, panel, CHAT_TOGGLE_BACKGROUND)
	draw_text(r, .Bold, size, panel.x + 12 * scale, panel.y + 6 * scale, clock, BROWSE_TEXT)

	// The bar between the time and the quality button; taller than it looks, to
	// be easy to click.
	bar_x := panel.x + panel.w + pad
	bar_w := right - pad - bar_x
	if bar_w < 40 * scale {
		return
	}
	w.seek_bar = {bar_x, panel.y, bar_w, panel.h}
	track_h := VOD_BAR_HEIGHT * scale
	track := Rect{bar_x, panel.y + (panel.h - track_h) / 2, bar_w, track_h}
	draw_rect(r, track, CHAT_TOGGLE_BACKGROUND)
	draw_rect(r, {track.x, track.y, track.w * f32(pos / duration), track.h}, BROWSE_ACCENT)
	if in_rect(w.seek_bar, app.mouse.x, app.mouse.y) {
		// Where a click would go.
		draw_rect(r, {app.mouse.x - scale, track.y - 4 * scale, 2 * scale, track.h + 8 * scale}, BROWSE_TEXT)
	}
}
