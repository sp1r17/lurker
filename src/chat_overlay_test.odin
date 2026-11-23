package app

import "core:testing"

@(test)
chat_overlay_goes_in_its_corner :: proc(t: ^testing.T) {
	screen := Rect{0, 0, 2560, 1440}
	r := chat_overlay_rect(screen, .Bottom_Right, .Medium, 1)
	testing.expect_value(t, r, Rect{2560 - 640 - 24, 1440 - 864 - 24, 640, 864})
	l := chat_overlay_rect(screen, .Top_Left, .Small, 1)
	testing.expect_value(t, l.x, 24)
	testing.expect_value(t, l.y, 24)
	// Never narrower than the chat's own width, room allowing.
	narrow := chat_overlay_rect({0, 0, 800, 600}, .Top_Left, .Small, 1)
	testing.expect_value(t, narrow.w, CHAT_WIDTH)
}

@(test)
enum_names_read_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, enum_from_name(Chat_Overlay_Position, "Top_Left", .Bottom_Right), Chat_Overlay_Position.Top_Left)
	testing.expect_value(t, enum_from_name(Chat_Overlay_Size, "Huge", .Medium), Chat_Overlay_Size.Medium)
}
