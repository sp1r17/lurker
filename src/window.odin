package app

import "base:runtime"
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
		if w.show_tab.w > 0 && in_rect(w.show_tab, x, y) {
			return false
		}
		return in_rect(w.video_rect, x, y)
	case .Browse:
		if app.sign_in.sign_out.w > 0 && in_rect(app.sign_in.sign_out, x, y) {
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
	if clicks == 2 && app.screen == .Watch {
		toggle_fullscreen(app)
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
