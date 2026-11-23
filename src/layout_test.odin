package app

import "core:testing"

@(test)
layout_keeps_valid_channels :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	data := `{"splits":{"lirik":["northernlion","bad&name","xqc"],"bad name":["x"]}}`
	testing.expect(t, parse_layout(transmute([]byte)data, &l))
	testing.expect_value(t, len(l.splits), 1)
	splits := l.splits["lirik"]
	testing.expect_value(t, len(splits), 2)
	testing.expect_value(t, splits[1], "xqc")
	testing.expect(t, !parse_layout(transmute([]byte)string(`{"splits":`), &l))
}

@(test)
layout_volume_defaults_when_missing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	old: Layout
	defer layout_destroy(&old)
	old.volume = DEFAULT_VOLUME
	old.text_size = DEFAULT_TEXT_SIZE
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{}}`), &old))
	testing.expect_value(t, old.volume, DEFAULT_VOLUME)

	saved: Layout
	defer layout_destroy(&saved)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"volume":0,"muted":true,"quality":"720p","low_latency":true,"hide_chat":true,"text_size":120,"notifications_off":true,"chat_sync":true,"latency_buffer_ms":2000,"max_height":720,"next_clip_off":true}`), &saved))
	testing.expect(t, saved.chat_sync)
	testing.expect_value(t, saved.latency_buffer_ms, 2000)
	testing.expect_value(t, saved.max_height, 720)
	testing.expect(t, saved.next_clip_off)
	// Values not offered are left at their defaults.
	odd: Layout
	defer layout_destroy(&odd)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"latency_buffer_ms":777,"max_height":999}`), &odd))
	testing.expect_value(t, odd.latency_buffer_ms, 0)
	testing.expect_value(t, odd.max_height, 0)
	chat: Layout
	defer layout_destroy(&chat)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"chat_timestamps":true,"chat_hide_bots":true}`), &chat))
	testing.expect(t, chat.chat.timestamps)
	testing.expect(t, chat.chat.hide_bots)
	testing.expect(t, !chat.chat.highlight_staff)
	testing.expect(t, !chat.chat.alternate_lines)
	sorted: Layout
	defer layout_destroy(&sorted)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"stream_sort":"Started","start_view":"History"}`), &sorted))
	testing.expect_value(t, sorted.stream_sort, Stream_Sort.Started)
	testing.expect_value(t, sorted.start_view, Browse_View.History)
	// Only a tab can be the start page.
	not_a_tab: Layout
	defer layout_destroy(&not_a_tab)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"start_view":"Settings"}`), &not_a_tab))
	testing.expect_value(t, not_a_tab.start_view, Browse_View.Following)
	testing.expect_value(t, saved.volume, 0)
	testing.expect(t, saved.muted)
	testing.expect_value(t, quality_name(saved.quality), "720p")
	testing.expect(t, saved.low_latency)
	testing.expect(t, saved.hide_chat)
	testing.expect(t, !old.hide_chat)
	testing.expect(t, saved.notifications_off)
	testing.expect(t, !old.notifications_off)
	testing.expect_value(t, saved.text_size, 120)
	testing.expect_value(t, old.text_size, DEFAULT_TEXT_SIZE)
	testing.expect_value(t, old.quality, QUALITY_SOURCE)

	loud: Layout
	defer layout_destroy(&loud)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"volume":400,"text_size":500}`), &loud))
	testing.expect_value(t, loud.volume, MAX_VOLUME)
	testing.expect_value(t, loud.text_size, MAX_TEXT_SIZE)
}

@(test)
layout_reads_video_enhancement :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"video_enhancement":"Upscale"}`), &l))
	testing.expect_value(t, l.video_enhancement, Video_Enhancement.Upscale)
	// A name from a newer version: the file is still read, with the default.
	newer: Layout
	defer layout_destroy(&newer)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"video_enhancement":"Sharpest","volume":40}`), &newer))
	testing.expect_value(t, newer.video_enhancement, Video_Enhancement.Off)
	testing.expect_value(t, newer.volume, 40)
	off, off_upscales := video_options(.Off)
	testing.expect_value(t, off, "")
	testing.expect(t, !off_upscales)
	balanced, balanced_upscales := video_options(.Balanced)
	testing.expect(t, balanced != "")
	testing.expect(t, !balanced_upscales)
}
