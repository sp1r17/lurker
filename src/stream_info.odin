package app

import "core:fmt"
import "core:strings"
import "core:time"

// The watched stream's title and game can change mid-stream; this often they're
// looked up again.
STREAM_INFO_REFRESH_MS :: 60_000
STREAM_INFO_BACKGROUND :: Color{0, 0, 0, 170}

Stream_Info_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	login:     string,
	// The watch it's for; dropped if that's over.
	session:   int,
	check:     Auth_Check,
	ok:        bool,
	// Whether the channel is live; `stream` is set only if so. Owned.
	live:      bool,
	stream:    Stream,
}

destroy_stream_info_job :: proc(p: ^Stream_Info_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.login)
	destroy_stream(p.stream)
}

// Looks up the stream's details when they're due, if signed in (Helix needs a
// token). Returns ms until the next lookup, for the main loop's wait.
stream_info_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	if app.screen != .Watch || !app.signed_in || w.info_pending {
		return -1
	}
	due := w.info_at + STREAM_INFO_REFRESH_MS
	if w.info_at != 0 && app.assets.now_ms < due {
		return due - app.assets.now_ms
	}
	w.info_pending = true
	jobs_add(
		&app.assets.jobs,
		run_stream_info_job,
		Stream_Info_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth),
			login = strings.clone(w.channel),
			session = app.session,
		},
	)
	return -1
}

@(private = "file")
run_stream_info_job :: proc(job: ^Job) {
	p := &job.payload.(Stream_Info_Job)
	p.check = .Valid
	streams, err := get_live_streams(p.client_id, p.auth.access_token, {p.login})
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		streams, err = get_live_streams(p.client_id, p.auth.access_token, {p.login})
	}
	if err != .None {
		return
	}
	p.ok = true
	if len(streams) > 0 {
		p.live = true
		p.stream = clone_stream(streams[0])
	}
}

finish_stream_info_job :: proc(app: ^App, p: ^Stream_Info_Job) {
	apply_auth_check(app, p.check, p.auth)
	w := &app.watch
	if app.screen != .Watch || p.session != app.session {
		return
	}
	w.info_pending = false
	// Even a failed lookup waits for the next refresh, rather than retrying at once.
	w.info_at = max(app.assets.now_ms, 1)
	if p.ok && p.live {
		watch_set_info(app, p.stream)
	}
}

// Replaces the shown stream details with a copy of `s`.
watch_set_info :: proc(app: ^App, s: Stream) {
	w := &app.watch
	if w.has_info {
		destroy_stream(w.info)
	}
	w.info = clone_stream(s)
	w.has_info = true
}

// "2:05:09": how long the stream has been live, from Helix's RFC 3339 start time.
format_uptime :: proc(started_at: string, now: time.Time) -> (text: string, ok: bool) {
	started, consumed := time.rfc3339_to_time_utc(started_at)
	if consumed == 0 {
		return "", false
	}
	seconds := max(0, int(time.duration_seconds(time.diff(started, now))))
	return fmt.tprintf("%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60), true
}

// Whether the video's controls and the stream info bar are showing.
controls_visible :: proc(app: ^App) -> bool {
	return app.assets.now_ms < app.watch.controls_until || app.watch.quality_menu
}

// The stream info bar's height, in pixels.
stream_info_height :: proc(app: ^App) -> f32 {
	r := &app.assets.renderer
	scale := app.scale
	return 2 * 14 * scale + line_height(r, .Bold, 20 * scale) + line_height(r, .Regular, BROWSE_CARD_TEXT_SIZE * scale)
}

// A bar across the top of the video: the channel and game, the title below, and
// viewers and uptime on the right. Shown with the video's other controls.
draw_stream_info :: proc(app: ^App) {
	w := &app.watch
	w.back_button = {}
	w.follow_button = {}
	w.unfollow_armed = w.unfollow_armed && controls_visible(app)
	if !controls_visible(app) {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	pad := 14 * scale
	name_size := 20 * scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	name_h := line_height(r, .Bold, name_size)
	lh := line_height(r, .Regular, size)
	v := w.video_rect
	bar := Rect{v.x, v.y, v.w, stream_info_height(app)}
	draw_rect(r, bar, STREAM_INFO_BACKGROUND)

	// A back button at the left, so the mouse alone can leave the stream.
	w.back_button = {bar.x, bar.y, 52 * scale, bar.h}
	if in_rect(w.back_button, app.mouse.x, app.mouse.y) {
		draw_rect(r, w.back_button, WINDOW_BUTTON_HOVER)
	}
	// Noto Sans has no arrows ("←" drew as a missing-glyph box); its chevron matches
	// the chats' "»" and "«".
	draw_centered(r, .Bold, 44 * scale, w.back_button, "‹", BROWSE_TEXT)

	// Right side first, so the text on the left knows how much room it has: the
	// window buttons, then viewers and uptime.
	right := draw_window_controls(app, bar.x + bar.w, bar.y) - pad
	if follow_left := draw_follow_button(app, right, bar.y + pad + name_h / 2); follow_left < right {
		right = follow_left - 16 * scale
	}
	if w.has_info {
		parts := make([dynamic]string, context.temp_allocator)
		append(&parts, format_viewers(w.info.viewer_count))
		if uptime, ok := format_uptime(w.info.started_at, time.now()); ok {
			append(&parts, uptime)
		}
		stats := strings.join(parts[:], "   ", context.temp_allocator)
		sw := text_width(r, .Regular, size, stats)
		y := bar.y + pad + (name_h - lh) / 2
		draw_text(r, .Regular, size, right - sw, y, stats, BROWSE_TEXT)
		dot := 8 * scale
		draw_rect(r, {right - sw - dot - 8 * scale, y + (lh - dot) / 2, dot, dot}, LIVE_RED)
		right -= sw + dot + 24 * scale
	}

	x := w.back_button.x + w.back_button.w
	name := w.info.user_name if w.has_info && w.info.user_name != "" else w.channel
	name = fit_text(r, .Bold, name_size, name, right - x)
	x = draw_text(r, .Bold, name_size, x, bar.y + pad, name, BROWSE_TEXT)
	title_x := w.back_button.x + w.back_button.w
	if w.playing_vod {
		when_ := format_last_live(w.vod.created_at, time.now())
		ago := strings.to_lower(when_[len("Live "):], context.temp_allocator) if strings.has_prefix(when_, "Live ") else when_
		past := fmt.tprintf("  ·  %s, %s", VIDEO_KIND_NAMES[w.vod.kind], ago)
		game_y := bar.y + pad + (name_h - lh) / 2
		draw_text(r, .Regular, size, x, game_y, fit_text(r, .Regular, size, past, right - x), BROWSE_ACCENT)
		draw_text_line(&app.assets, .Regular, size, title_x, bar.y + pad + name_h, w.vod.title, BROWSE_DIM_TEXT, right - title_x)
		return
	}
	if !w.has_info {
		return
	}
	if w.info.game_name != "" {
		game := fmt.tprintf("  ·  %s", w.info.game_name)
		game_y := bar.y + pad + (name_h - lh) / 2
		draw_text(r, .Regular, size, x, game_y, fit_text(r, .Regular, size, game, right - x), BROWSE_ACCENT)
	}
	draw_text_line(&app.assets, .Regular, size, title_x, bar.y + pad + name_h, w.info.title, BROWSE_DIM_TEXT, right - title_x)
}
