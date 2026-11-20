package app

import "core:testing"

@(test)
log_tail_keeps_short_logs :: proc(t: ^testing.T) {
	testing.expect_value(t, log_tail("one\ntwo\n", 100), "one\ntwo\n")
}

@(test)
log_tail_starts_at_a_line :: proc(t: ^testing.T) {
	// The last 9 bytes start inside "second": the tail begins after it.
	testing.expect_value(t, log_tail("first\nsecond\nthird\n", 9), "third\n")
}
