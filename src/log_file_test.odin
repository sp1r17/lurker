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

@(test)
log_scrub_numbers_private_values :: proc(t: ^testing.T) {
	text := "minute of ‹moonmoon›\nbonus on ‹lirik›\nminute of ‹moonmoon›\n"
	testing.expect_value(t, log_scrub(text, ""), "minute of ‹1›\nbonus on ‹2›\nminute of ‹1›\n")
}

@(test)
log_scrub_leaves_unmatched_marks :: proc(t: ^testing.T) {
	// A › only on the next line isn't a pair.
	text := "chat said ‹ hi\nand › bye\n"
	testing.expect_value(t, log_scrub(text, ""), text)
}

@(test)
log_scrub_replaces_the_home_folder :: proc(t: ^testing.T) {
	text := "can't save /home/alice/.config/lurker/layout.json\n/home/alicea stays\n"
	testing.expect_value(t, log_scrub(text, "/home/alice"), "can't save ~/.config/lurker/layout.json\n/home/alicea stays\n")
	windows := `can't save C:\Users\Alice\AppData\Local\lurker\x`
	testing.expect_value(t, log_scrub(windows, `C:\Users\Alice`), `can't save ~\AppData\Local\lurker\x`)
}

@(test)
log_scrub_drops_url_queries :: proc(t: ^testing.T) {
	text := `GET /helix/users?login=moonmoon returned 500: {"url":"https://usher.ttvnw.net/x.m3u8?sig=abc&token=def"} (what?)`
	testing.expect_value(t, log_scrub(text, ""), `GET /helix/users?… returned 500: {"url":"https://usher.ttvnw.net/x.m3u8?…"} (what?)`)
}

@(test)
log_scrub_hides_private_values_in_urls :: proc(t: ^testing.T) {
	text := "minute of ‹MoonMoon›\nimage https://static-cdn.jtvnw.net/previews-ttv/live_user_moonmoon-440x248.jpg: HTTP 404\nmoonmoon in prose stays\n"
	testing.expect_value(t, log_scrub(text, ""), "minute of ‹1›\nimage https://static-cdn.jtvnw.net/previews-ttv/live_user_‹1›-440x248.jpg: HTTP 404\nmoonmoon in prose stays\n")
}
