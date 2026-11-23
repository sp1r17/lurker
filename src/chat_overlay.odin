package app

import "core:fmt"
import "core:math"

// Chat over the video in fullscreen (Layout.chat_overlay): the video takes the
// whole screen, and the chats show in a box over it, in a corner, at a size and
// with a background chosen in Settings.

Chat_Overlay_Position :: enum {
	Bottom_Right,
	Top_Right,
	Bottom_Left,
	Top_Left,
}

Chat_Overlay_Size :: enum {
	Medium,
	Small,
	Large,
}

// How much of the video shows through the chat's background.
Chat_Overlay_Background :: enum {
	Dim,
	Clear,
	Solid,
}

CHAT_OVERLAY_POSITION_LABELS :: [Chat_Overlay_Position]string {
	.Bottom_Right = "Bottom right",
	.Top_Right    = "Top right",
	.Bottom_Left  = "Bottom left",
	.Top_Left     = "Top left",
}

CHAT_OVERLAY_SIZE_LABELS :: [Chat_Overlay_Size]string {
	.Small  = "Small",
	.Medium = "Medium",
	.Large  = "Large",
}

CHAT_OVERLAY_BACKGROUND_LABELS :: [Chat_Overlay_Background]string {
	.Dim   = "Dimmed",
	.Clear = "Mostly clear",
	.Solid = "Solid",
}

// Each size's share of the screen's width and height.
@(private = "file")
CHAT_OVERLAY_SHARES :: [Chat_Overlay_Size][2]f32 {
	.Small  = {0.2, 0.45},
	.Medium = {0.25, 0.6},
	.Large  = {0.32, 0.8},
}

// Whether the chats show over the video now.
chat_overlay_on :: proc(app: ^App) -> bool {
	return app.fullscreen && app.layout.chat_overlay && app.watch.show_chat
}

// Where the chats go over a video filling `screen`: in the chosen corner, the
// chosen share of it, clear of the edges.
chat_overlay_rect :: proc(screen: Rect, position: Chat_Overlay_Position, size: Chat_Overlay_Size, scale: f32) -> Rect {
	shares := CHAT_OVERLAY_SHARES
	margin := 24 * scale
	w := max(screen.w * shares[size].x, min(CHAT_WIDTH * scale, screen.w - 2 * margin))
	h := screen.h * shares[size].y
	x := screen.x + margin
	if position == .Bottom_Right || position == .Top_Right {
		x = screen.x + screen.w - w - margin
	}
	y := screen.y + margin
	if position == .Bottom_Right || position == .Bottom_Left {
		y = screen.y + screen.h - h - margin
	}
	// Whole pixels, so the text in it stays sharp.
	return {math.round(x), math.round(y), math.round(w), math.round(h)}
}

// The chat's background over the video.
chat_overlay_background :: proc(b: Chat_Overlay_Background) -> Color {
	c := CHAT_BACKGROUND
	switch b {
	case .Dim:
		c.a = 170
	case .Clear:
		c.a = 80
	case .Solid:
		c.a = 255
	}
	return c
}

// An enum value saved by its name, read back: `fallback` for a name this
// version doesn't know.
enum_from_name :: proc($T: typeid, name: string, fallback: T) -> T {
	for v in T {
		if fmt.tprint(v) == name {
			return v
		}
	}
	return fallback
}
