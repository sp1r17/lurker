package app

import "core:testing"

@(test)
blocked_names_compare_without_case :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bl: Blocked
	defer blocked_destroy(&bl)
	testing.expect(t, blocked_add(&bl, .Channel, " @MoonMoon "))
	testing.expect_value(t, bl.channels[0], "moonmoon")
	testing.expect(t, !blocked_add(&bl, .Channel, "moonmoon"))
	testing.expect(t, !blocked_add(&bl, .Channel, "not a login"))
	testing.expect(t, blocked_add(&bl, .Category, "Just Chatting"))
	testing.expect(t, !blocked_add(&bl, .Category, "just chatting"))
	testing.expect(t, !blocked_add(&bl, .Category, "  "))

	testing.expect(t, is_blocked(&bl, .Channel, "MOONMOON"))
	testing.expect(t, is_blocked(&bl, .Category, "JUST CHATTING"))
	testing.expect(t, !is_blocked(&bl, .Category, "moonmoon"))
	testing.expect(t, !is_blocked(&bl, .Category, ""))
	testing.expect(t, stream_blocked(&bl, Stream{user_login = "lirik", game_name = "Just Chatting"}))
	testing.expect(t, !stream_blocked(&bl, Stream{user_login = "lirik", game_name = "Minecraft"}))

	blocked_remove(&bl, .Channel, 0)
	testing.expect(t, !is_blocked(&bl, .Channel, "moonmoon"))
	blocked_remove(&bl, .Channel, 5)
}
