package app

import "core:testing"

@(test)
viewer_counts_read_like_twitch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, format_viewers(999), "999")
	testing.expect_value(t, format_viewers(1000), "1K")
	testing.expect_value(t, format_viewers(1234), "1.2K")
	testing.expect_value(t, format_viewers(25_100), "25.1K")
	testing.expect_value(t, format_viewers(2_000_000), "2M")
}

@(test)
streams_page_has_cursor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":[{"user_id":"1","user_login":"lirik","user_name":"LIRIK","game_name":"G","title":"T",` +
		`"viewer_count":11300,"thumbnail_url":"https://x/live_user_lirik-{width}x{height}.jpg"}],` +
		`"pagination":{"cursor":"abc"}}`
	streams, cursor, err := parse_streams_page(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, cursor, "abc")
	testing.expect_value(t, len(streams), 1)
	testing.expect_value(t, streams[0].thumbnail_url, "https://x/live_user_lirik-{width}x{height}.jpg")

	_, last_cursor, _ := parse_streams_page(transmute([]byte)string(`{"data":[],"pagination":{}}`))
	testing.expect_value(t, last_cursor, "")
}
