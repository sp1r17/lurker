package app

import "core:fmt"
import "core:strings"
import "core:time"

// How often the stream stats redraw while the video is paused or still, for the
// clocks and the network figures.
STATS_REDRAW_MS :: 1000
// How often Twitch is pinged while the stats show, and where: the server live
// streams' playlists come from.
PING_INTERVAL_MS :: 5000
PING_HOST :: "usher.ttvnw.net"

// The last ping to Twitch and the average of all this watch's, in ms.
Ping_Stats :: struct {
	last:    f64,
	total:   f64,
	count:   int,
	// When the last one started (Assets.now_ms; 0 for never), and whether it's
	// still under way.
	sent_at: int,
	pending: bool,
}

Ping_Job :: struct {
	// The watch it's for.
	session: int,
	ms:      f64,
	ok:      bool,
}

// Pings Twitch every PING_INTERVAL_MS while the stats show. Returns ms until the
// next, for the main loop's wait.
ping_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	if app.screen != .Watch || !app.layout.stats || w.ping.pending {
		return -1
	}
	now := app.assets.now_ms
	due := w.ping.sent_at + PING_INTERVAL_MS
	if w.ping.sent_at != 0 && now < due {
		return due - now
	}
	w.ping.sent_at = max(now, 1)
	w.ping.pending = true
	jobs_add(&app.assets.jobs, run_ping_job, Ping_Job{session = app.session})
	return -1
}

@(private = "file")
run_ping_job :: proc(job: ^Job) {
	p := &job.payload.(Ping_Job)
	p.ms, p.ok = http_ping(PING_HOST)
}

finish_ping_job :: proc(app: ^App, p: ^Ping_Job) {
	w := &app.watch
	if app.screen != .Watch || p.session != app.session {
		return
	}
	w.ping.pending = false
	if p.ok {
		w.ping.last = p.ms
		w.ping.total += p.ms
		w.ping.count += 1
	}
}

// Shows or hides the stream stats over the video (I), and remembers it.
watch_toggle_stats :: proc(app: ^App) {
	app.watch.quality_menu = false
	app.layout.stats = !app.layout.stats
	layout_save(&app.layout)
}

// One row of the stats: what it is, and its value.
Stats_Row :: struct {
	label: string,
	value: string,
}

// The stats' rows, from what mpv reports: the video, bitrates, network, buffer,
// dropped frames; the ping to Twitch; and how long the stream has been live
// (`started_at`, "" for a video) and watched (`watched_s`). Allocated with the
// temp allocator.
stats_rows :: proc(s: Player_Stats, ping: Ping_Stats, started_at: string, watched_s: int, now: time.Time) -> []Stats_Row {
	rows := make([dynamic]Stats_Row, context.temp_allocator)
	unknown :: "—"

	video := unknown
	if height, ok := s.height.?; ok && height > 0 {
		parts := make([dynamic]string, context.temp_allocator)
		fps := s.fps.? or_else 0
		append(&parts, fmt.tprintf("%dp%d", height, int(fps + 0.5)) if fps > 0 else fmt.tprintf("%dp", height))
		if s.codec != "" {
			append(&parts, codec_name(s.codec))
		}
		append(&parts, "software decoding" if s.hwdec == "" || s.hwdec == "no" else fmt.tprintf("hardware (%s)", s.hwdec))
		video = strings.join(parts[:], " · ", context.temp_allocator)
	}
	append(&rows, Stats_Row{"Video", video})

	bitrate := unknown
	if v, ok := s.video_bitrate.?; ok {
		bitrate = format_bits(v)
		if a, has_audio := s.audio_bitrate.?; has_audio {
			bitrate = fmt.tprintf("%s video · %s audio", bitrate, format_bits(a))
		}
	}
	append(&rows, Stats_Row{"Bitrate", bitrate})

	network := unknown
	if speed, ok := s.net_speed.?; ok {
		network = format_bits(speed * 8)
		if elapsed := time.duration_seconds(time.tick_since(s.loaded_at)); elapsed >= 1 && s.received > 0 {
			network = fmt.tprintf("%s · %s average", network, format_bits(s.received * 8 / elapsed))
		}
	}
	append(&rows, Stats_Row{"Network", network})
	append(&rows, Stats_Row{"Data used", format_bytes(s.received) if s.received > 0 else unknown})

	buffer := unknown
	if b, ok := s.buffer.?; ok {
		buffer = fmt.tprintf("%.1f s", b)
	}
	append(&rows, Stats_Row{"Buffer", buffer})
	ping_text := unknown
	if ping.count > 0 {
		ping_text = fmt.tprintf("%.0f ms · %.0f ms average", ping.last, ping.total / f64(ping.count))
	}
	append(&rows, Stats_Row{"Ping to Twitch", ping_text})
	append(&rows, Stats_Row{"Dropped frames", fmt.tprintf("%d (%d by the decoder)", s.dropped + s.decoder_dropped, s.decoder_dropped)})

	if uptime, ok := format_uptime(started_at, now); ok {
		append(&rows, Stats_Row{"Live for", uptime})
	}
	append(&rows, Stats_Row{"Watching for", format_clock(watched_s)})
	return rows[:]
}

// "H.264" for mpv's "h264", and so on; others in capitals.
@(private = "file")
codec_name :: proc(codec: string) -> string {
	switch codec {
	case "h264":
		return "H.264"
	case "hevc":
		return "H.265"
	case "av1":
		return "AV1"
	case "aac":
		return "AAC"
	}
	return strings.to_upper(codec, context.temp_allocator)
}

// "6.2 Mb/s", "160 kb/s": a rate in bits per second. Allocated with the temp
// allocator.
format_bits :: proc(bits_per_second: f64) -> string {
	switch {
	case bits_per_second >= 1_000_000:
		return fmt.tprintf("%.1f Mb/s", bits_per_second / 1_000_000)
	case bits_per_second >= 1000:
		return fmt.tprintf("%.0f kb/s", bits_per_second / 1000)
	}
	return fmt.tprintf("%.0f b/s", bits_per_second)
}

// "412 MB", "1.3 GB". Allocated with the temp allocator.
format_bytes :: proc(bytes: f64) -> string {
	switch {
	case bytes >= 1_000_000_000:
		return fmt.tprintf("%.1f GB", bytes / 1_000_000_000)
	case bytes >= 1_000_000:
		return fmt.tprintf("%.0f MB", bytes / 1_000_000)
	}
	return fmt.tprintf("%.0f kB", bytes / 1000)
}

// The stats over the video's top left, below the stream info bar while that
// shows, if they're turned on and something's playing.
draw_stream_stats :: proc(app: ^App) {
	w := &app.watch
	if !app.layout.stats || w.status != .Playing {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	lh := line_height(r, .Regular, size)
	pad := 10 * scale
	gap := 16 * scale
	started_at := w.info.started_at if w.has_info && !w.playing_vod else ""
	watched := (app.assets.now_ms - w.watching_since) / 1000
	rows := stats_rows(app.player.stats, w.ping, started_at, watched, time.now())

	label_w, value_w: f32
	for row in rows {
		label_w = max(label_w, text_width(r, .Regular, size, row.label))
		value_w = max(value_w, text_width(r, .Bold, size, row.value))
	}
	v := w.video_rect
	top := v.y + 16 * scale
	if controls_visible(app) {
		top = v.y + stream_info_height(app) + 8 * scale
	}
	panel := Rect{v.x + 16 * scale, top, min(label_w + gap + value_w + 2 * pad, v.w - 32 * scale), f32(len(rows)) * lh + 2 * pad}
	draw_rect(r, panel, VIEWERS_BACKGROUND)
	value_x := panel.x + pad + label_w + gap
	for row, i in rows {
		y := panel.y + pad + f32(i) * lh
		draw_text(r, .Regular, size, panel.x + pad, y, row.label, BROWSE_DIM_TEXT)
		draw_text(r, .Bold, size, value_x, y, fit_text(r, .Bold, size, row.value, panel.x + panel.w - pad - value_x), BROWSE_TEXT)
	}
	// The clocks and the network figures move on while the picture doesn't.
	a := &app.assets
	if a.next_frame_ms < 0 || STATS_REDRAW_MS < a.next_frame_ms {
		a.next_frame_ms = STATS_REDRAW_MS
	}
}
