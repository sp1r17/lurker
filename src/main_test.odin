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
	_, err = parse_config(transmute([]byte)string(`{"channels": []}`))
	testing.expect_value(t, err, Config_Error.No_Channels)
	_, err = parse_config(transmute([]byte)string(`{"channels": `))
	testing.expect_value(t, err, Config_Error.Bad_Json)
}

@(test)
status_is_split_from_body :: proc(t: ^testing.T) {
	res, err := split_status(transmute([]byte)string("{\"a\":1}\n200"))
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, res.status, 200)
	testing.expect_value(t, string(res.body), `{"a":1}`)
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
streams_url_lists_every_login :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(
		t,
		streams_url({"a", "b"}),
		"https://api.twitch.tv/helix/streams?first=100&user_login=a&user_login=b",
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
