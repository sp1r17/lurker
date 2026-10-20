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
