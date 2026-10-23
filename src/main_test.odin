package app

import "core:testing"

@(test)
config_lowercases_channels_and_defaults_poll :: proc(t: ^testing.T) {
	c, err := parse_config(transmute([]byte)string(`{"channels": ["Shroud", "lirik"]}`))
	defer destroy_config(c)
	testing.expect_value(t, err, Config_Error.None)
	testing.expect_value(t, c.channels[0], "shroud")
	testing.expect_value(t, c.poll_seconds, 60)
}

@(test)
config_rejects_bad_channels :: proc(t: ^testing.T) {
	_, err := parse_config(transmute([]byte)string(`{"channels": ["a&first=1"]}`))
	testing.expect_value(t, err, Config_Error.Bad_Channel)
	_, err = parse_config(transmute([]byte)string(`{"channels": `))
	testing.expect_value(t, err, Config_Error.Bad_Json)
}

@(test)
config_defaults_when_empty :: proc(t: ^testing.T) {
	c, err := parse_config(transmute([]byte)string(`{}`))
	defer destroy_config(c)
	testing.expect_value(t, err, Config_Error.None)
	testing.expect_value(t, len(c.channels), 0)
	testing.expect_value(t, c.client_id, "")
}

@(test)
token_is_parsed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	token, err := parse_token_response(
		transmute([]byte)string(`{"access_token":"abc","expires_in":5000000,"token_type":"bearer"}`),
	)
	defer delete(token)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, token, "abc")
}

@(test)
streams_are_parsed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":[{"id":"1","user_login":"lirik","user_name":"LIRIK","game_name":"Just Chatting",` +
		`"type":"live","title":"hi","viewer_count":1234,"started_at":"2026-10-20T12:00:00Z"}],"pagination":{}}`
	streams, err := parse_streams_response(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, len(streams), 1)
	testing.expect_value(t, streams[0].user_name, "LIRIK")
	testing.expect_value(t, streams[0].viewer_count, 1234)
}

@(test)
streams_path_lists_every_login :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(
		t,
		streams_path({"a", "b"}),
		"/streams?first=100&user_login=a&user_login=b",
	)
}

@(test)
live_set_reports_changes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	live: Live_Set
	defer destroy_live_set(&live)

	changes := update_live_set(&live, {{user_login = "a"}, {user_login = "b"}})
	testing.expect_value(t, len(changes.went_live), 2)
	testing.expect_value(t, len(changes.went_offline), 0)

	changes = update_live_set(&live, {{user_login = "b"}, {user_login = "c"}})
	testing.expect_value(t, len(changes.went_live), 1)
	testing.expect_value(t, changes.went_live[0].user_login, "c")
	testing.expect_value(t, len(changes.went_offline), 1)
	testing.expect_value(t, changes.went_offline[0], "a")
	testing.expect_value(t, len(live), 2)
}

@(test)
invisible_characters_are_not_drawn :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, visible_text("PEPW ͏"), "PEPW ")
	testing.expect_value(t, visible_text("hi \U000E0000"), "hi ")
	// Emoji sequences keep their joiners.
	testing.expect_value(t, visible_text("👨‍👩"), "👨‍👩")
	plain := "nothing to strip"
	testing.expect(t, raw_data(visible_text(plain)) == raw_data(plain))
}
