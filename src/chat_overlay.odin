package app

import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"

// Chat over the video in fullscreen (Layout.chat_overlay): the video takes the
// whole screen, and the chats show in a box over it, in a corner, at a size and
// with a background chosen in Settings. Dragging a header moves the box and
// dragging its edges resizes it (Layout.chat_overlay_box); choosing a corner or
// size in Settings puts it back.

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

// Whether the chats go over the video, fullscreen with the setting on: they show
// there whether or not they're hidden beside it (Layout.hide_chat), until C
// hides them for this watch.
chat_overlay_mode :: proc(app: ^App) -> bool {
	return app.fullscreen && app.layout.chat_overlay
}

// Whether the chats show over the video now.
chat_overlay_on :: proc(app: ^App) -> bool {
	return chat_overlay_mode(app) && !app.watch.overlay_hidden
}

// Whether the chats are showing: over the video, or beside it.
chats_shown :: proc(app: ^App) -> bool {
	return chat_overlay_on(app) if chat_overlay_mode(app) else app.watch.show_chat
}

// Shows or hides the chats: over the video, for this watch; beside it, as the
// setting kept for every channel (watch_show_chat).
watch_toggle_chats :: proc(app: ^App, show: bool) {
	if chat_overlay_mode(app) {
		app.watch.overlay_hidden = !show
		return
	}
	watch_show_chat(app, show)
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

// How far each side of the box's edges a press resizes it, in logical pixels.
CHAT_OVERLAY_GRAB :: 5
// The smallest the box can be made, in logical pixels.
CHAT_OVERLAY_MIN :: [2]f32{220, 200}

Chat_Overlay_Edge :: enum {
	Left,
	Right,
	Top,
	Bottom,
}

// The box being moved or resized with the mouse.
Chat_Overlay_Drag :: struct {
	active: bool,
	// The edges being dragged; none moves the whole box.
	edges:  bit_set[Chat_Overlay_Edge],
	from:   [2]f32,
	start:  Rect,
}

// Where the chats go over a video filling `screen`: where they were dragged, or
// else in the corner and at the size chosen in Settings.
chat_overlay_box :: proc(app: ^App, screen: Rect) -> Rect {
	l := &app.layout
	b := l.chat_overlay_box
	if b[2] <= 0 || b[3] <= 0 {
		return chat_overlay_rect(screen, l.chat_overlay_position, l.chat_overlay_size, app.scale)
	}
	r := Rect{screen.x + b[0] * screen.w, screen.y + b[1] * screen.h, b[2] * screen.w, b[3] * screen.h}
	return chat_overlay_clamp(r, screen, app.scale)
}

// `r` made no smaller than CHAT_OVERLAY_MIN and moved onto `screen`.
chat_overlay_clamp :: proc(r, screen: Rect, scale: f32) -> Rect {
	min_size := CHAT_OVERLAY_MIN * scale
	r := r
	r.w = clamp(r.w, min(min_size.x, screen.w), screen.w)
	r.h = clamp(r.h, min(min_size.y, screen.h), screen.h)
	r.x = clamp(r.x, screen.x, screen.x + screen.w - r.w)
	r.y = clamp(r.y, screen.y, screen.y + screen.h - r.h)
	return {math.round(r.x), math.round(r.y), math.round(r.w), math.round(r.h)}
}

// The box `d` started from, with the mouse now at (x, y): moved, or with the
// dragged edges following the mouse, kept on `screen` and no smaller than
// CHAT_OVERLAY_MIN.
chat_overlay_dragged :: proc(d: Chat_Overlay_Drag, x, y: f32, screen: Rect, scale: f32) -> Rect {
	s := d.start
	dx, dy := x - d.from.x, y - d.from.y
	if d.edges == {} {
		return chat_overlay_clamp({s.x + dx, s.y + dy, s.w, s.h}, screen, scale)
	}
	min_size := CHAT_OVERLAY_MIN * scale
	left, right := s.x, s.x + s.w
	top, bottom := s.y, s.y + s.h
	if .Left in d.edges {
		left = clamp(left + dx, screen.x, right - min_size.x)
	}
	if .Right in d.edges {
		right = clamp(right + dx, left + min_size.x, screen.x + screen.w)
	}
	if .Top in d.edges {
		top = clamp(top + dy, screen.y, bottom - min_size.y)
	}
	if .Bottom in d.edges {
		bottom = clamp(bottom + dy, top + min_size.y, screen.y + screen.h)
	}
	return {math.round(left), math.round(top), math.round(right - left), math.round(bottom - top)}
}

// What a press at (x, y) would grab of the box: its edges, to resize it, or a
// header (no edges), to move it. Not `ok` off them, and on the headers' buttons.
chat_overlay_grab_at :: proc(app: ^App, x, y: f32) -> (edges: bit_set[Chat_Overlay_Edge], ok: bool) {
	w := &app.watch
	if !chat_overlay_on(app) || len(w.panes) == 0 {
		return {}, false
	}
	if w.hide_button.w > 0 && in_rect(w.hide_button, x, y) {
		return {}, false
	}
	for p in w.panes {
		if p.mention_badge.w > 0 && in_rect(p.mention_badge, x, y) {
			return {}, false
		}
	}
	b := w.overlay_rect
	g := CHAT_OVERLAY_GRAB * app.scale
	if x < b.x - g || x >= b.x + b.w + g || y < b.y - g || y >= b.y + b.h + g {
		return {}, false
	}
	if x < b.x + g {
		edges += {.Left}
	} else if x >= b.x + b.w - g {
		edges += {.Right}
	}
	if y < b.y + g {
		edges += {.Top}
	} else if y >= b.y + b.h - g {
		edges += {.Bottom}
	}
	if edges != {} {
		return edges, true
	}
	for p in w.panes {
		if in_rect(p.header_rect, x, y) {
			return {}, true
		}
	}
	return {}, false
}

// Whether (x, y) is on the box or close enough to its edges to resize it.
on_chat_overlay :: proc(app: ^App, x, y: f32) -> bool {
	if !chat_overlay_on(app) {
		return false
	}
	b := app.watch.overlay_rect
	g := CHAT_OVERLAY_GRAB * app.scale
	return in_rect({b.x - g, b.y - g, b.w + 2 * g, b.h + 2 * g}, x, y)
}

// A left press at (x, y): starts moving or resizing the box if it's on a header
// or an edge. Returns true if it did.
chat_overlay_press :: proc(app: ^App, x, y: f32) -> bool {
	edges, ok := chat_overlay_grab_at(app, x, y)
	if !ok {
		return false
	}
	w := &app.watch
	w.overlay_drag = {
		active = true,
		edges  = edges,
		from   = {x, y},
		start  = w.overlay_rect,
	}
	return true
}

// The mouse moved to (x, y) with the left button down: the box follows. Saved
// once it's let go (chat_overlay_release).
chat_overlay_drag_motion :: proc(app: ^App, x, y: f32) {
	w := &app.watch
	if !w.overlay_drag.active {
		return
	}
	if !chat_overlay_on(app) {
		w.overlay_drag = {}
		return
	}
	screen := w.overlay_screen
	if screen.w <= 0 || screen.h <= 0 {
		return
	}
	r := chat_overlay_dragged(w.overlay_drag, x, y, screen, app.scale)
	app.layout.chat_overlay_box = {(r.x - screen.x) / screen.w, (r.y - screen.y) / screen.h, r.w / screen.w, r.h / screen.h}
}

// The left button let go: a moved or resized box is kept for next time.
chat_overlay_release :: proc(app: ^App) {
	w := &app.watch
	if !w.overlay_drag.active {
		return
	}
	moved := w.overlay_rect != w.overlay_drag.start
	w.overlay_drag = {}
	if moved {
		layout_save(&app.layout)
	}
}

// The mouse cursor for the box under the mouse, or being dragged: arrows on its
// edges, a move cursor on its headers.
chat_overlay_cursor :: proc(app: ^App) -> sdl.SystemCursor {
	w := &app.watch
	edges: bit_set[Chat_Overlay_Edge]
	ok := w.overlay_drag.active
	if ok {
		edges = w.overlay_drag.edges
	} else if app.screen == .Watch {
		edges, ok = chat_overlay_grab_at(app, app.mouse.x, app.mouse.y)
	}
	if !ok {
		return .DEFAULT
	}
	switch edges {
	case {}:
		return .MOVE
	case {.Left, .Top}, {.Right, .Bottom}:
		return .NWSE_RESIZE
	case {.Right, .Top}, {.Left, .Bottom}:
		return .NESW_RESIZE
	case {.Left}, {.Right}:
		return .EW_RESIZE
	}
	return .NS_RESIZE
}

// The system cursors in use, made the first time each is needed.
@(private = "file")
overlay_cursors: [sdl.SystemCursor]^sdl.Cursor
@(private = "file")
overlay_cursor_shown: sdl.SystemCursor

// Shows chat_overlay_cursor, if it's not already showing.
chat_overlay_update_cursor :: proc(app: ^App) {
	want := chat_overlay_cursor(app)
	if want == overlay_cursor_shown {
		return
	}
	if overlay_cursors[want] == nil {
		overlay_cursors[want] = sdl.CreateSystemCursor(want)
		if overlay_cursors[want] == nil {
			return
		}
	}
	if sdl.SetCursor(overlay_cursors[want]) {
		overlay_cursor_shown = want
	}
}
