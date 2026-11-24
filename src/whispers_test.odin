package app

import "core:testing"

@(test)
whispers_leave_out_your_own :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"whisperThread":{"messages":{"edges":[` +
		`{"node":{"id":"m2","sentAt":"2026-11-23T21:00:05Z","from":{"id":"9","displayName":"Friend"},"content":{"content":"hey"}}},` +
		`{"node":{"id":"m1","sentAt":"2026-11-23T21:00:00Z","from":{"id":"1","displayName":"Me"},"content":{"content":"hi"}}}]}}}}`
	list := parse_whispers(transmute([]byte)body, "1")
	testing.expect_value(t, len(list), 1)
	testing.expect_value(t, list[0], Whisper{"m2", "2026-11-23T21:00:05Z", "Friend", "hey"})
	testing.expect_value(t, len(parse_whispers(transmute([]byte)string(`{"data":{"whisperThread":null}}`), "1")), 0)
}

@(test)
whisper_send_errors_are_told :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, whisper_send_error(transmute([]byte)string(`{"data":{"sendWhisper":{"message":{"id":"w1"},"error":null}}}`)), "")
	testing.expect_value(t, whisper_send_error(transmute([]byte)string(`{"data":{"sendWhisper":{"message":null,"error":{"code":"RECIPIENT_BLOCKED_USER"}}}}`)), "Twitch said RECIPIENT_BLOCKED_USER")
	testing.expect_value(t, whisper_send_error(transmute([]byte)string(`{"errors":[{"message":"server error"}],"data":{"sendWhisper":{"message":null,"error":null}}}`)), "Twitch said \"server error\"")
}
