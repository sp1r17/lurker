package app

import "core:encoding/endian"
import "core:fmt"
import "core:strings"
import "core:time"

// Latency to broadcaster, for the stream stats: how far behind the moment Twitch
// received it the picture on screen is.
//
// Every live segment's #EXT-X-PROGRAM-DATE-TIME is when Twitch received it from
// the broadcaster (it matches the ingest time in the segment's own "ld_lat_data"
// metadata; the broadcaster's send time is left out, so the upload isn't
// counted). The segment's fragment starts at a media time (its tfdt), the same
// clock mpv's position runs on for a live stream. So one anchor, the segment's
// time less its media time, turns mpv's position into the wall-clock time the
// frame on screen was received, and the latency is now less that.

// How often the anchor is taken again, in case the stream restarts or streamlink
// cutting out ads moves the media time on.
LATENCY_REFRESH_MS :: 30_000
// Enough of a segment for its first fragment's header: Twitch puts a metadata
// box (about 400 bytes) and then the moof (about 260) first.
SEGMENT_HEAD_BYTES :: 8192

Latency_Stats :: struct {
	// The live stream's media playlist, from streamlink ("" until looked up).
	// Owned.
	playlist:   string,
	// Unix seconds at media time 0, once taken.
	anchor:     Maybe(f64),
	// When it was last taken (Assets.now_ms), and whether that's under way.
	taken_at:   int,
	pending:    bool,
}

latency_reset :: proc(l: ^Latency_Stats) {
	delete(l.playlist)
	l^ = {}
}

// Seconds behind the broadcaster at mpv position `position`, if the anchor is
// known.
latency_seconds :: proc(l: Latency_Stats, position: f64, now: time.Time) -> (seconds: f64, ok: bool) {
	anchor := l.anchor.? or_return
	return unix_seconds(now) - (anchor + position), true
}

@(private = "file")
unix_seconds :: proc(t: time.Time) -> f64 {
	return f64(time.time_to_unix_nano(t)) / 1e9
}

Latency_Job :: struct {
	// The stream it's for (Watch.started_at, which a restart changes).
	session:    int,
	started_at: int,
	channel:    string,
	quality:    Quality,
	renditions: Renditions,
	client_id:  string,
	token:      string,
	// The playlist to use ("" to look it up), and then the one used. Owned.
	playlist:   string,
	anchor:     f64,
	ok:         bool,
}

destroy_latency_job :: proc(p: ^Latency_Job) {
	delete(p.channel)
	delete(p.client_id)
	delete(p.token)
	delete(p.playlist)
}

// Takes the anchor every LATENCY_REFRESH_MS while the stats show over a live
// stream. Returns ms until the next, for the main loop's wait.
latency_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	l := &w.latency
	if app.screen != .Watch || !app.layout.stats || w.playing_vod || w.status != .Playing || l.pending {
		return -1
	}
	now := app.assets.now_ms
	due := l.taken_at + LATENCY_REFRESH_MS
	if l.taken_at != 0 && now < due {
		return due - now
	}
	l.taken_at = max(now, 1)
	l.pending = true
	job := Latency_Job {
		session    = app.session,
		started_at = w.started_at,
		channel    = strings.clone(w.channel),
		quality    = app.layout.quality,
		renditions = w.qualities,
		playlist   = strings.clone(l.playlist),
	}
	if w.signed_stream {
		job.client_id = strings.clone(app.client_id)
		job.token = strings.clone(app.auth.access_token)
	}
	jobs_add(&app.assets.jobs, run_latency_job, job)
	return -1
}

@(private = "file")
run_latency_job :: proc(job: ^Job) {
	p := &job.payload.(Latency_Job)
	if p.playlist != "" {
		if p.anchor, p.ok = stream_anchor(p.playlist); p.ok {
			return
		}
		// Its token may have run out: a new one, below.
		delete(p.playlist)
		p.playlist = ""
	}
	url, found := streamlink_live_playlist(p.channel, p.quality, p.renditions, p.client_id, p.token)
	if !found {
		return
	}
	p.playlist = url
	p.anchor, p.ok = stream_anchor(p.playlist)
}

finish_latency_job :: proc(app: ^App, p: ^Latency_Job) {
	w := &app.watch
	if app.screen != .Watch || p.session != app.session || p.started_at != w.started_at {
		return
	}
	l := &w.latency
	l.pending = false
	delete(l.playlist)
	l.playlist, p.playlist = p.playlist, ""
	if p.ok {
		l.anchor = p.anchor
	}
}

// The anchor from the newest segment of the media playlist at `url`: its time,
// less its media time. Blocks: for a job.
@(private = "file")
stream_anchor :: proc(url: string) -> (anchor: f64, ok: bool) {
	res := http_request(url, allocator = context.temp_allocator) or_return
	if res.status != 200 {
		return 0, false
	}
	init_url, segment_url, received := parse_latency_playlist(string(res.body)) or_return
	init := http_request(init_url, allocator = context.temp_allocator) or_return
	if init.status != 200 {
		return 0, false
	}
	head := http_request(
		segment_url,
		{fmt.tprintf("Range: bytes=0-%d", SEGMENT_HEAD_BYTES - 1)},
		allocator = context.temp_allocator,
	) or_return
	if head.status != 200 && head.status != 206 {
		return 0, false
	}
	start := fragment_start(head.body, init.body) or_return
	return received - start, true
}

// The newest segment in a live media playlist: its init segment's address
// (EXT-X-MAP), its own, and when Twitch received it (Unix seconds). False for
// a playlist without them, such as one of MPEG-TS segments.
parse_latency_playlist :: proc(text: string) -> (init_url, segment_url: string, received: f64, ok: bool) {
	pending: Maybe(f64)
	text := text
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_right_space(raw)
		switch {
		case strings.has_prefix(line, "#EXT-X-MAP:"):
			if i := strings.index(line, `URI="`); i >= 0 {
				rest := line[i + len(`URI="`):]
				if j := strings.index_byte(rest, '"'); j >= 0 {
					init_url = rest[:j]
				}
			}
		case strings.has_prefix(line, "#EXT-X-PROGRAM-DATE-TIME:"):
			t, consumed := time.rfc3339_to_time_utc(line[len("#EXT-X-PROGRAM-DATE-TIME:"):])
			pending = unix_seconds(t) if consumed > 0 else nil
		case line != "" && !strings.has_prefix(line, "#"):
			// A segment: the newest one with a time so far.
			if t, has_time := pending.?; has_time {
				segment_url, received = line, t
			}
			pending = nil
		}
	}
	return init_url, segment_url, received, init_url != "" && segment_url != ""
}

// When the first fragment in `segment` (its start, at least) begins, in
// seconds of media time: its first track's tfdt, in that track's timescale from
// the init segment `init`.
fragment_start :: proc(segment, init: []byte) -> (seconds: f64, ok: bool) {
	moof := mp4_find(segment, "moof") or_return
	rest := moof
	for box in mp4_next(&rest) {
		if box.type != "traf" {
			continue
		}
		tfhd := mp4_find(box.body, "tfhd") or_return
		tfdt := mp4_find(box.body, "tfdt") or_return
		track := endian.get_u32(tfhd[4:], .Big) or_return
		scale := track_timescale(init, track) or_return
		base: u64
		if len(tfdt) > 0 && tfdt[0] == 1 {
			base = endian.get_u64(tfdt[4:], .Big) or_return
		} else {
			base = u64(endian.get_u32(tfdt[4:], .Big) or_return)
		}
		return f64(base) / f64(scale), scale > 0
	}
	return 0, false
}

// Track `track`'s timescale, from the init segment's moov.
@(private = "file")
track_timescale :: proc(init: []byte, track: u32) -> (scale: u32, ok: bool) {
	moov := mp4_find(init, "moov") or_return
	rest := moov
	for box in mp4_next(&rest) {
		if box.type != "trak" {
			continue
		}
		tkhd := mp4_find(box.body, "tkhd") or_return
		mdia := mp4_find(box.body, "mdia") or_return
		mdhd := mp4_find(mdia, "mdhd") or_return
		// Version 1 has 64-bit times before the ID and the timescale.
		offset := 20 if len(tkhd) > 0 && tkhd[0] == 1 else 12
		id := endian.get_u32(tkhd[offset:], .Big) or_return
		if id != track {
			continue
		}
		offset = 20 if len(mdhd) > 0 && mdhd[0] == 1 else 12
		return endian.get_u32(mdhd[offset:], .Big)
	}
	return 0, false
}

Mp4_Box :: struct {
	type: string,
	body: []byte,
}

// The next box in `data`, which moves past it. One cut short (by a ranged
// request) gives what's there.
@(private = "file")
mp4_next :: proc(data: ^[]byte) -> (box: Mp4_Box, ok: bool) {
	d := data^
	size32 := endian.get_u32(d, .Big) or_return
	if len(d) < 8 {
		return {}, false
	}
	size, header := int(size32), 8
	switch size32 {
	case 0:
		size = len(d)
	case 1:
		size64 := endian.get_u64(d[8:], .Big) or_return
		size, header = int(size64), 16
	}
	if size < header || header > len(d) {
		return {}, false
	}
	end := min(size, len(d))
	data^ = d[end:]
	return {string(d[4:8]), d[header:end]}, true
}

// The body of the first `type` box among the boxes in `data`.
@(private = "file")
mp4_find :: proc(data: []byte, type: string) -> (body: []byte, ok: bool) {
	rest := data
	for box in mp4_next(&rest) {
		if box.type == type {
			return box.body, true
		}
	}
	return nil, false
}
