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
	testing.expect_value(t, enum_from_name(Chat_Overlay_Position, "Top_Left", Chat_Overlay_Position.Bottom_Right), Chat_Overlay_Position.Top_Left)
	testing.expect_value(t, enum_from_name(Chat_Overlay_Size, "Huge", Chat_Overlay_Size.Medium), Chat_Overlay_Size.Medium)
}

@(test)
chat_overlay_moves_and_resizes :: proc(t: ^testing.T) {
	screen := Rect{0, 0, 1920, 1080}
	start := Rect{100, 100, 400, 500}
	// Moved, but not off the screen.
	moved := chat_overlay_dragged({active = true, from = {150, 110}, start = start}, 250, 160, screen, 1)
	testing.expect_value(t, moved, Rect{200, 150, 400, 500})
	off := chat_overlay_dragged({active = true, from = {150, 110}, start = start}, -500, 5000, screen, 1)
	testing.expect_value(t, off, Rect{0, 1080 - 500, 400, 500})
	// The bottom-right corner follows the mouse; the top-left stays.
	grown := chat_overlay_dragged({active = true, edges = {.Right, .Bottom}, from = {500, 600}, start = start}, 700, 650, screen, 1)
	testing.expect_value(t, grown, Rect{100, 100, 600, 550})
	// The left edge stops at the smallest width, the right edge staying put.
	shrunk := chat_overlay_dragged({active = true, edges = {.Left}, from = {100, 300}, start = start}, 480, 300, screen, 1)
	testing.expect_value(t, shrunk, Rect{500 - CHAT_OVERLAY_MIN.x, 100, CHAT_OVERLAY_MIN.x, 500})
}

@(test)
chat_overlay_box_is_read_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"chat_overlay_box":[0.5,0.25,0.25,0.5]}`), &l))
	testing.expect_value(t, l.chat_overlay_box, [4]f32{0.5, 0.25, 0.25, 0.5})
	// A box saved for one screen keeps its shares on another, kept on it.
	app: App
	app.scale = 1
	app.layout.chat_overlay_box = l.chat_overlay_box
	testing.expect_value(t, chat_overlay_box(&app, {0, 0, 1000, 800}), Rect{500, 200, 250, 400})
	app.layout.chat_overlay_box = {0.9, 0.9, 0.5, 0.5}
	testing.expect_value(t, chat_overlay_box(&app, {0, 0, 1000, 800}), Rect{500, 400, 500, 400})
}
