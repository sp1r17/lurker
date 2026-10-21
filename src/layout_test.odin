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
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"volume":0,"muted":true,"quality":"720p","low_latency":true,"hide_chat":true,"text_size":120}`), &saved))
	testing.expect_value(t, saved.volume, 0)
	testing.expect(t, saved.muted)
	testing.expect_value(t, saved.quality, Quality.P720)
	testing.expect(t, saved.low_latency)
	testing.expect(t, saved.hide_chat)
	testing.expect(t, !old.hide_chat)
	testing.expect_value(t, saved.text_size, 120)
	testing.expect_value(t, old.text_size, DEFAULT_TEXT_SIZE)
	testing.expect_value(t, old.quality, Quality.Source)

	loud: Layout
	defer layout_destroy(&loud)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"volume":400,"text_size":500}`), &loud))
	testing.expect_value(t, loud.volume, MAX_VOLUME)
	testing.expect_value(t, loud.text_size, MAX_TEXT_SIZE)
}
