package app

import "core:testing"

@(test)
live_notifier_announces_new_streams :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n: Live_Notifier
	defer live_notifier_destroy(&n)
	a := Stream{user_id = "1", user_name = "A"}
	b := Stream{user_id = "2", user_name = "B"}
	c := Stream{user_id = "3", user_name = "C"}

	// Those live at the start aren't announced.
	testing.expect_value(t, len(live_notifier_update(&n, {a, b}, 0)), 0)
	testing.expect_value(t, len(live_notifier_update(&n, {a, b}, LIVE_POLL_MS)), 0)

	went_live := live_notifier_update(&n, {a, b, c}, 2 * LIVE_POLL_MS)
	testing.expect_value(t, len(went_live), 1)
	testing.expect_value(t, went_live[0], 2)
}

@(test)
live_notifier_ignores_brief_drops :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n: Live_Notifier
	defer live_notifier_destroy(&n)
	a := Stream{user_id = "1"}
	b := Stream{user_id = "2"}
	live_notifier_update(&n, {a, b}, 0)

	// A restarted stream, back a poll later.
	live_notifier_update(&n, {b}, LIVE_POLL_MS)
	testing.expect_value(t, len(live_notifier_update(&n, {a, b}, 2 * LIVE_POLL_MS)), 0)

	// Gone for longer, then back: live again.
	now := 2 * LIVE_POLL_MS
	for now < 2 * LIVE_POLL_MS + LIVE_GRACE_MS + LIVE_POLL_MS {
		now += LIVE_POLL_MS
		live_notifier_update(&n, {b}, now)
	}
	testing.expect_value(t, len(n.last_seen), 1)
	testing.expect_value(t, len(live_notifier_update(&n, {a, b}, now + LIVE_POLL_MS)), 1)
}

@(test)
live_notifier_survives_a_long_gap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n: Live_Notifier
	defer live_notifier_destroy(&n)
	a := Stream{user_id = "1"}
	live_notifier_update(&n, {a}, 0)
	// Asleep for hours, still live: not announced again.
	testing.expect_value(t, len(live_notifier_update(&n, {a}, 5 * 60 * 60_000)), 0)

	// After signing out, the next list is a new start.
	live_notifier_clear(&n)
	testing.expect_value(t, len(live_notifier_update(&n, {a}, 0)), 0)
}

@(test)
live_notification_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	title, body := live_notification({user_name = "MOONMOON", title = "dark souls", game_name = "Elden Ring"})
	testing.expect_value(t, title, "MOONMOON is live")
	testing.expect_value(t, body, "dark souls\nElden Ring")
	_, body = live_notification({user_name = "a", game_name = "Just Chatting"})
	testing.expect_value(t, body, "Just Chatting")

	streams := []Stream{{user_name = "A"}, {user_name = "B"}, {user_name = "C"}, {user_name = "D"}}
	title, body = live_notification_summary(streams)
	testing.expect_value(t, title, "4 channels you follow are live")
	testing.expect_value(t, body, "A, B, C and D")
	_, body = live_notification_summary(streams[:2])
	testing.expect_value(t, body, "A and B")
}
