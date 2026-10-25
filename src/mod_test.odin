package app

import "core:testing"

@(test)
timeouts_parse :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		seconds: int,
		ok:      bool,
	}
	cases := []Case{{"600", 600, true}, {"30s", 30, true}, {"10m", 600, true}, {"1h", 3600, true}, {"1d", 86400, true}, {"2w", 1_209_600, true}, {"3w", 0, false}, {"0", 0, false}, {"-5m", 0, false}, {"spam", 0, false}, {"m", 0, false}, {"", 0, false}}
	for c in cases {
		seconds, ok := parse_timeout(c.text)
		testing.expectf(t, ok == c.ok && seconds == c.seconds, "%q: got %d %v", c.text, seconds, ok)
	}
}

@(test)
helix_errors_are_readable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"error":"Bad Request","status":400,"message":"The user specified in the user_id field is already banned."}`
	testing.expect_value(t, helix_error_message(transmute([]byte)string(body), 400), "The user specified in the user_id field is already banned.")
	testing.expect_value(t, helix_error_message(nil, 500), "Twitch said 500")
}
