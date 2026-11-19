package app

import "core:testing"

@(test)
stream_lists_sort_with_their_thumbnails :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Stream_List
	l.streams = make([dynamic]Stream, context.temp_allocator)
	l.thumbnails = make([dynamic]string, context.temp_allocator)
	append(&l.streams, Stream{user_name = "beta", game_name = "Zelda", viewer_count = 900, started_at = "2026-11-19T10:00:00Z"})
	append(&l.streams, Stream{user_name = "Alpha", game_name = "Apex", viewer_count = 100, started_at = "2026-11-19T12:00:00Z"})
	append(&l.streams, Stream{user_name = "gamma", game_name = "Minecraft", viewer_count = 500, started_at = "2026-11-19T11:00:00Z"})
	append(&l.thumbnails, "b.jpg", "a.jpg", "g.jpg")
	stream_list_sort(&l, .Name)
	testing.expect_value(t, l.streams[0].user_name, "Alpha")
	testing.expect_value(t, l.thumbnails[0], "a.jpg")
	testing.expect_value(t, l.thumbnails[2], "g.jpg")
	stream_list_sort(&l, .Started)
	testing.expect_value(t, l.streams[0].user_name, "Alpha")
	testing.expect_value(t, l.streams[2].user_name, "beta")
	stream_list_sort(&l, .Category)
	testing.expect_value(t, l.streams[0].game_name, "Apex")
	testing.expect_value(t, l.thumbnails[1], "g.jpg")
	stream_list_sort(&l, .Viewers)
	testing.expect_value(t, l.streams[0].viewer_count, 900)
	testing.expect_value(t, l.thumbnails[0], "b.jpg")
}

@(test)
history_times_read_as_ago :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, format_ago(1000, 1010), "Just now")
	testing.expect_value(t, format_ago(0, 3 * 3600), "3 hours ago")
	testing.expect_value(t, format_ago(0, 86400), "1 day ago")
}
