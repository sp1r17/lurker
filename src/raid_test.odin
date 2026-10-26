package app

import "core:encoding/json"
import "core:testing"

@(test)
eventsub_messages_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	welcome := `{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"AQoQ","keepalive_timeout_seconds":30}}}`
	e, kind := parse_eventsub(welcome)
	testing.expect_value(t, kind, Eventsub_Kind.Event)
	testing.expect_value(t, e.session, "AQoQ")
	destroy_raid_event(e)

	raid := `{"metadata":{"message_type":"notification"},"payload":{"subscription":{"type":"channel.raid"},` +
		`"event":{"from_broadcaster_user_login":"moonmoon","from_broadcaster_user_name":"MOONMOON",` +
		`"to_broadcaster_user_login":"lirik","to_broadcaster_user_name":"LIRIK","viewers":9001}}}`
	e, kind = parse_eventsub(raid)
	testing.expect_value(t, kind, Eventsub_Kind.Event)
	testing.expect_value(t, e.to_login, "lirik")
	testing.expect_value(t, e.to_name, "LIRIK")
	testing.expect_value(t, e.from_name, "MOONMOON")
	testing.expect_value(t, e.session, "")
	destroy_raid_event(e)

	_, kind = parse_eventsub(`{"metadata":{"message_type":"session_keepalive"},"payload":{}}`)
	testing.expect_value(t, kind, Eventsub_Kind.Other)
	_, kind = parse_eventsub(`{"metadata":{"message_type":"session_reconnect"},"payload":{"session":{"reconnect_url":"wss://x"}}}`)
	testing.expect_value(t, kind, Eventsub_Kind.Reconnect)
	_, kind = parse_eventsub(`not json`)
	testing.expect_value(t, kind, Eventsub_Kind.Other)
}

@(test)
raid_subscription_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := raid_subscription("121059319", "AQoQ")
	parsed, err := json.parse_string(body, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root := parsed.(json.Object)
	testing.expect_value(t, root["type"].(json.String), "channel.raid")
	testing.expect_value(t, root["version"].(json.String), "1")
	testing.expect_value(t, root["condition"].(json.Object)["from_broadcaster_user_id"].(json.String), "121059319")
	transport := root["transport"].(json.Object)
	testing.expect_value(t, transport["method"].(json.String), "websocket")
	testing.expect_value(t, transport["session_id"].(json.String), "AQoQ")

	id, id_err := parse_user_id(transmute([]byte)string(`{"data":[{"id":"121059319","login":"moonmoon"}]}`))
	testing.expect_value(t, id_err, Twitch_Error.None)
	testing.expect_value(t, id, "121059319")
	_, none := parse_user_id(transmute([]byte)string(`{"data":[]}`))
	testing.expect_value(t, none, Twitch_Error.Bad_Json)
}

@(test)
following_raids_is_saved_in_the_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	parse_layout(transmute([]byte)string(`{"raids_off":true}`), &l)
	testing.expect(t, l.raids_off)
}
