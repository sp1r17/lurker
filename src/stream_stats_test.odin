package app

import "core:testing"
import "core:time"

@(test)
rates_and_sizes_read_naturally :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, format_bits(6_240_000), "6.2 Mb/s")
	testing.expect_value(t, format_bits(160_000), "160 kb/s")
	testing.expect_value(t, format_bytes(412_000_000), "412 MB")
	testing.expect_value(t, format_bytes(1_300_000_000), "1.3 GB")
}

@(test)
card_uptime_reads_in_hours_and_minutes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	now, _ := time.rfc3339_to_time_utc("2026-11-19T15:00:30Z")
	text, next_ms, ok := format_card_uptime("2026-11-19T12:55:00Z", now)
	testing.expect(t, ok)
	testing.expect_value(t, text, "2h 05m")
	testing.expect_value(t, next_ms, 30_000)
	text, _, _ = format_card_uptime("2026-11-19T14:15:00Z", now)
	testing.expect_value(t, text, "45m")
	_, _, ok = format_card_uptime("", now)
	testing.expect(t, !ok)
}

@(test)
stats_rows_describe_playback :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	now, _ := time.rfc3339_to_time_utc("2026-11-19T15:00:00Z")
	s := Player_Stats {
		height          = 936,
		fps             = 59.94,
		codec           = "h264",
		hwdec           = "vaapi",
		video_bitrate   = 6_000_000,
		audio_bitrate   = 160_000,
		buffer          = 2.34,
		dropped         = 3,
		decoder_dropped = 1,
	}
	rows := stats_rows(s, {last = 21.4, total = 60, count = 3}, 2.43, "2026-11-19T12:00:00Z", 125, now)
	get :: proc(rows: []Stats_Row, label: string) -> string {
		for r in rows {
			if r.label == label {
				return r.value
			}
		}
		return "(none)"
	}
	testing.expect_value(t, get(rows, "Video"), "936p60 · H.264 · hardware (vaapi)")
	testing.expect_value(t, get(rows, "Bitrate"), "6.0 Mb/s video · 160 kb/s audio")
	testing.expect_value(t, get(rows, "Network"), "—")
	testing.expect_value(t, get(rows, "Buffer"), "2.3 s")
	testing.expect_value(t, get(rows, "Ping to Twitch"), "21 ms · 20 ms average")
	testing.expect_value(t, get(rows, "Latency to broadcaster"), "2.4 s")
	testing.expect_value(t, get(stats_rows(s, {}, nil, "2026-11-19T12:00:00Z", 0, now), "Latency to broadcaster"), "—")
	// A video: no latency.
	testing.expect_value(t, get(stats_rows(s, {}, 2.43, "", 0, now), "Latency to broadcaster"), "(none)")
	testing.expect_value(t, get(stats_rows({}, {}, nil, "", 0, now), "Ping to Twitch"), "—")
	testing.expect_value(t, get(rows, "Dropped frames"), "4 (1 by the decoder)")
	testing.expect_value(t, get(rows, "Live for"), "3:00:00")
	testing.expect_value(t, get(rows, "Watching for"), format_clock(125))
	// A video: no uptime.
	testing.expect_value(t, get(stats_rows({}, {}, nil, "", 0, now), "Live for"), "(none)")
	testing.expect_value(t, get(stats_rows({hwdec = "no", height = 720}, {}, nil, "", 0, now), "Video"), "720p · software decoding")
}

@(test)
upscaling_text_tells_running_from_idle :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, upscaling_text(false, {1280, 720}, {2560, 1440}), "Off")
	// 720p in 1440p: twice its size, so the shader runs.
	testing.expect_value(t, upscaling_text(true, {1280, 720}, {2560, 1440}), "On · 720p to 1440p (2.0×)")
	// 1080p beside the chat on a 1440p screen: fitted to the narrower width.
	testing.expect_value(t, upscaling_text(true, {1920, 1080}, {2220, 1400}), "Idle · drawn at 1.16×, needs over 1.3×")
	// Nothing known yet.
	testing.expect_value(t, upscaling_text(true, {0, 0}, {2560, 1440}), "On")
}
