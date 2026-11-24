package app

import "core:fmt"

// Lowering a live stream's quality when it keeps buffering: when its position
// stops moving though it isn't paused (whether mpv waits for its cache or, with
// low latency, just runs dry) BUFFERING_STALLS times within BUFFERING_WINDOW_MS,
// it plays one rendition lower until the quality is picked again or the watch
// ends. The quality saved isn't changed: it's the network now, not for good.

// How long the position must stand still to count as a stall.
BUFFERING_STALL_MS :: 1000
BUFFERING_STALLS :: 3
BUFFERING_WINDOW_MS :: 60_000
// How often it's checked while a live stream plays.
BUFFERING_CHECK_MS :: 250

Buffering :: struct {
	// When the position last moved (0: not yet watching), and where it was.
	moved_at: int,
	last_pos: f64,
	// In a stall now, already counted.
	stalled:  bool,
	// When the stalls within the window began, oldest first.
	stalls:   [BUFFERING_STALLS]int,
	count:    int,
}

// Starts over, as after the stream (re)starts.
buffering_reset :: proc(b: ^Buffering) {
	b^ = {}
}

// Takes the player's position at `now` (nil while it has none), and whether it's
// paused. Returns true when the stream has stalled often enough to lower its
// quality, and starts over.
buffering_update :: proc(b: ^Buffering, now: int, pos: Maybe(f64), paused: bool) -> (lower: bool) {
	p, has_pos := pos.?
	if !has_pos || paused || b.moved_at == 0 {
		b.moved_at = now
		b.last_pos = p
		b.stalled = false
		return false
	}
	if p != b.last_pos {
		b.last_pos = p
		b.moved_at = now
		b.stalled = false
		return false
	}
	if b.stalled || now - b.moved_at < BUFFERING_STALL_MS {
		return false
	}
	b.stalled = true
	// Forget the stalls too old to count, then add this one.
	kept := 0
	for s in b.stalls[:b.count] {
		if now - s <= BUFFERING_WINDOW_MS {
			b.stalls[kept] = s
			kept += 1
		}
	}
	b.count = kept
	if b.count == BUFFERING_STALLS {
		copy(b.stalls[:], b.stalls[1:])
		b.count -= 1
	}
	b.stalls[b.count] = b.moved_at
	b.count += 1
	if b.count >= BUFFERING_STALLS {
		buffering_reset(b)
		return true
	}
	return false
}

// The rendition below the one `q` plays in `r`; false if it's the lowest (or
// they aren't known). Never audio only.
quality_lower :: proc(q: Quality, r: Renditions) -> (lower: Quality, ok: bool) {
	if !renditions_known(r) {
		return {}, false
	}
	r := r
	playing := quality_playing(q, r)
	for v, i in r.video[:r.count] {
		if v == playing && i + 1 < r.count {
			return r.video[i + 1], true
		}
	}
	return {}, false
}

// Checks a live stream for buffering, and lowers its quality when it keeps at
// it. Returns ms until it's next due, for the main loop's wait.
buffering_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	if app.screen != .Watch || w.playing_vod || w.status != .Playing || app.layout.auto_quality_off {
		buffering_reset(&w.buffering)
		return -1
	}
	pos: Maybe(f64)
	if p, ok := player_position(&app.player); ok {
		pos = p
	}
	if buffering_update(&w.buffering, max(app.assets.now_ms, 1), pos, player_paused(&app.player)) {
		watch_lower_quality(app)
	}
	return BUFFERING_CHECK_MS
}

// Plays the live stream one rendition lower, for this watch, and says so.
@(private = "file")
watch_lower_quality :: proc(app: ^App) {
	w := &app.watch
	lower, ok := quality_lower(watch_quality(app), w.qualities)
	if !ok {
		return
	}
	w.quality_override = lower
	pane_notice(app, w.panes[0], fmt.tprintf("The stream kept buffering, so it's playing in %s now. Pick a quality to go back.", quality_label(lower)))
	restart_stream(app)
}
