package app

import "base:runtime"
import "core:math"
import sdl "vendor:sdl3"

// How close to the window's edge a press resizes it, in logical pixels.
RESIZE_BORDER :: 6
// How far the mouse moves with the button held before a press on the video becomes
// a drag, in logical pixels; less is a click.
DRAG_THRESHOLD :: 4

// The window is borderless, so this tells the compositor what a press means: the
// edges resize it. The video (and the browse header) drag it: through
// Wayland_Drag when that's set up, which lets the app see the clicks too, or else
// by marking them draggable here. Called by SDL on the main thread while it handles
// events.
window_hit_test :: proc "c" (window: ^sdl.Window, area: ^sdl.Point, data: rawptr) -> sdl.HitTestResult {
	context = runtime.default_context()
	app := (^App)(data)
	if .FULLSCREEN in sdl.GetWindowFlags(window) {
		return .NORMAL
	}

	w, h: i32
	sdl.GetWindowSize(window, &w, &h)
	x, y := area.x, area.y
	left, right := x < RESIZE_BORDER, x >= w - RESIZE_BORDER
	top, bottom := y < RESIZE_BORDER, y >= h - RESIZE_BORDER
	switch {
	case top && left:
		return .RESIZE_TOPLEFT
	case top && right:
		return .RESIZE_TOPRIGHT
	case bottom && left:
		return .RESIZE_BOTTOMLEFT
	case bottom && right:
		return .RESIZE_BOTTOMRIGHT
	case top:
		return .RESIZE_TOP
	case bottom:
		return .RESIZE_BOTTOM
	case left:
		return .RESIZE_LEFT
	case right:
		return .RESIZE_RIGHT
	}

	// The app's rects are in pixels; SDL's point is in window coordinates.
	density := sdl.GetWindowPixelDensity(window)
	px, py := f32(x) * density, f32(y) * density
	return .DRAGGABLE if !app.wayland_drag_ok && draggable(app, px, py) else .NORMAL
}

// Whether a press at (x, y), in pixels, should drag the window: somewhere that
// doesn't do anything else when clicked.
draggable :: proc(app: ^App, x, y: f32) -> bool {
	switch app.screen {
	case .Watch:
		w := &app.watch
		if w.card.open && in_rect(w.card.rect, x, y) {
			return false
		}
		if on_controls(app, x, y) || on_window_controls(app, x, y) {
			return false
		}
		if w.show_tab.w > 0 && in_rect(w.show_tab, x, y) {
			return false
		}
		return in_rect(w.video_rect, x, y)
	case .Browse:
		if app.sign_in.sign_out.w > 0 && in_rect(app.sign_in.sign_out, x, y) {
			return false
		}
		if on_window_controls(app, x, y) {
			return false
		}
		return y < BROWSE_HEADER_HEIGHT * app.scale
	}
	return false
}

toggle_fullscreen :: proc(app: ^App) {
	fullscreen := .FULLSCREEN in sdl.GetWindowFlags(app.window)
	sdl.SetWindowFullscreen(app.window, !fullscreen)
}

// A left press at (x, y), in pixels: a double-click on the video toggles
// fullscreen, and a press on a drag area may become a drag once the mouse moves.
window_press :: proc(app: ^App, x, y: f32, clicks: u8) {
	app.drag_armed = false
	if !draggable(app, x, y) {
		return
	}
	// Double-click: the video goes fullscreen; the browse header maximizes, like
	// a title bar.
	if clicks == 2 {
		switch app.screen {
		case .Watch:
			toggle_fullscreen(app)
		case .Browse:
			toggle_maximized(app)
		}
		return
	}
	if app.wayland_drag_ok && .FULLSCREEN not_in sdl.GetWindowFlags(app.window) {
		app.drag_armed = true
		app.drag_from = {x, y}
	}
}

// Mouse motion with the left button held: past the threshold, a press on a drag
// area starts moving the window.
window_drag_motion :: proc(app: ^App, x, y: f32) {
	if !app.drag_armed {
		return
	}
	d := [2]f32{x, y} - app.drag_from
	threshold := DRAG_THRESHOLD * app.scale
	if d.x * d.x + d.y * d.y >= threshold * threshold {
		app.drag_armed = false
		wayland_drag_start(&app.wayland_drag)
	}
}

Window_Control :: enum {
	Minimize,
	Maximize,
	Close,
}

// Logical pixels, like a title bar's buttons.
WINDOW_BUTTON :: [2]f32{46, 34}
WINDOW_BUTTON_HOVER :: Color{0xff, 0xff, 0xff, 30}
CLOSE_BUTTON_HOVER :: Color{0xe8, 0x11, 0x23, 255}

// Minimize, maximize (restore when maximized) and close, right-aligned at `right`,
// since the borderless window has no title bar. Returns the x of their left edge.
draw_window_controls :: proc(app: ^App, right, top: f32) -> (left: f32) {
	r := &app.assets.renderer
	scale := app.scale
	size := WINDOW_BUTTON * scale
	maximized := .MAXIMIZED in sdl.GetWindowFlags(app.window)
	x := right - size.x * len(Window_Control)
	for control in Window_Control {
		rect := Rect{x + f32(int(control)) * size.x, top, size.x, size.y}
		app.window_buttons[control] = rect
		if in_rect(rect, app.mouse.x, app.mouse.y) {
			draw_rect(r, rect, CLOSE_BUTTON_HOVER if control == .Close else WINDOW_BUTTON_HOVER)
		}
		// Icons drawn from rects stay crisp at any scale.
		cx, cy := rect.x + rect.w / 2, rect.y + rect.h / 2
		icon := 10 * scale
		line := max(1, math.round(scale))
		switch control {
		case .Minimize:
			draw_rect(r, {cx - icon / 2, cy, icon, line}, BROWSE_TEXT)
		case .Maximize:
			if maximized {
				// Two overlapping squares: restore.
				outline(r, {cx - icon / 2 + 2 * scale, cy - icon / 2 - 2 * scale, icon - 2 * scale, icon - 2 * scale}, line)
				draw_rect(r, {cx - icon / 2, cy - icon / 2, icon - 2 * scale, icon - 2 * scale}, CHAT_TOGGLE_BACKGROUND)
				outline(r, {cx - icon / 2, cy - icon / 2, icon - 2 * scale, icon - 2 * scale}, line)
			} else {
				outline(r, {cx - icon / 2, cy - icon / 2, icon, icon}, line)
			}
		case .Close:
			draw_centered(r, .Regular, 22 * scale, rect, "×", BROWSE_TEXT)
		}
	}
	return x
}

@(private = "file")
outline :: proc(r: ^Renderer, b: Rect, line: f32) {
	draw_rect(r, {b.x, b.y, b.w, line}, BROWSE_TEXT)
	draw_rect(r, {b.x, b.y + b.h - line, b.w, line}, BROWSE_TEXT)
	draw_rect(r, {b.x, b.y, line, b.h}, BROWSE_TEXT)
	draw_rect(r, {b.x + b.w - line, b.y, line, b.h}, BROWSE_TEXT)
}

// Whether (x, y) is on a window button drawn this frame.
on_window_controls :: proc(app: ^App, x, y: f32) -> bool {
	for rect in app.window_buttons {
		if rect.w > 0 && in_rect(rect, x, y) {
			return true
		}
	}
	return false
}

// Handles a click on the window buttons. Returns true if it was used.
window_controls_click :: proc(app: ^App, x, y: f32) -> bool {
	for rect, control in app.window_buttons {
		if rect.w == 0 || !in_rect(rect, x, y) {
			continue
		}
		switch control {
		case .Minimize:
			_ = sdl.MinimizeWindow(app.window)
		case .Maximize:
			toggle_maximized(app)
		case .Close:
			e: sdl.Event
			e.type = .QUIT
			_ = sdl.PushEvent(&e)
		}
		return true
	}
	return false
}

toggle_maximized :: proc(app: ^App) {
	if .MAXIMIZED in sdl.GetWindowFlags(app.window) {
		_ = sdl.RestoreWindow(app.window)
	} else {
		_ = sdl.MaximizeWindow(app.window)
	}
}
