package app

// Settings while watching: the Settings page in a window of its own over the
// stream, which keeps playing behind it. Its title bar moves it; × or Esc closes
// it. What the page's controls change applies to the stream playing, the stream
// settings by starting it again once they've settled (settings_stream_changed).

Settings_Window :: struct {
	open:     bool,
	// Where it is, in pixels: centred when first drawn (`placed` after).
	rect:     Rect,
	placed:   bool,
	// Its title bar, which moves it. Set while drawing.
	title:    Rect,
	// Being moved: where in it the mouse took hold.
	dragging: bool,
	grab:     [2]f32,
	// When to start the stream again after a stream setting changed (in
	// assets.now_ms), or 0.
	restart_at: int,
}

// Logical pixels: as wide as the Settings page's rows, and no taller than this.
SETTINGS_WINDOW_SIZE :: [2]f32{760, 680}
// How far it keeps from the window's edges, in logical pixels.
SETTINGS_WINDOW_MARGIN :: 24
// How long after the last click on a stream setting the stream starts again:
// stepping through a few values starts it only once.
SETTINGS_RESTART_MS :: 1200

settings_window_open :: proc(app: ^App) {
	sw := &app.watch.settings_window
	if sw.open || !app.signed_in {
		return
	}
	sw.open, sw.placed = true, false
	app.browse.settings.tip = ""
	app.browse.language_menu.open = false
	app.watch.quality_menu = false
}

settings_window_close :: proc(app: ^App) {
	sw := &app.watch.settings_window
	settings_unfocus(app)
	app.browse.language_menu.open = false
	sw.open, sw.dragging = false, false
}

settings_window_toggle :: proc(app: ^App) {
	if app.watch.settings_window.open {
		settings_window_close(app)
	} else {
		settings_window_open(app)
	}
}

// Whether (x, y) is on the settings window, which takes clicks and the wheel
// there.
on_settings_window :: proc(app: ^App, x, y: f32) -> bool {
	sw := &app.watch.settings_window
	if app.screen != .Watch || !sw.open {
		return false
	}
	return in_rect(sw.rect, x, y) || (app.browse.language_menu.open && in_rect(app.menu_rect, x, y))
}

// A left click while it's open. Returns true if it was the window's.
settings_window_click :: proc(app: ^App, x, y: f32) -> bool {
	sw := &app.watch.settings_window
	if !sw.open {
		return false
	}
	b := &app.browse
	// The language menu hangs below its row, maybe past the window's edge.
	if language_menu_click(app, x, y) {
		return true
	}
	b.language_menu.open = false
	if !in_rect(sw.rect, x, y) {
		// Typing in one of its boxes stops on a click elsewhere.
		settings_unfocus(app)
		return false
	}
	box_unfocus(app)
	switch {
	case b.back_button.w > 0 && in_rect(b.back_button, x, y):
		settings_window_close(app)
	case b.language_button.w > 0 && in_rect(b.language_button, x, y):
		b.language_menu.open = true
	case settings_click(app, x, y):
	case in_rect(sw.title, x, y):
		sw.dragging = true
		sw.grab = {x - sw.rect.x, y - sw.rect.y}
	}
	return true
}

settings_window_drag_motion :: proc(app: ^App, x, y: f32) {
	sw := &app.watch.settings_window
	if sw.open && sw.dragging {
		// Kept on screen when drawn (draw_settings_window).
		sw.rect.x, sw.rect.y = x - sw.grab.x, y - sw.grab.y
	}
}

settings_window_release :: proc(app: ^App) {
	app.watch.settings_window.dragging = false
}

// The wheel over it scrolls the page. Returns true if it was over it.
settings_window_scroll :: proc(app: ^App, x, y, wheel_y: f32) -> bool {
	if !on_settings_window(app, x, y) {
		return false
	}
	b := &app.browse
	b.language_menu.open = false
	b.scroll[.Settings] = clamp(b.scroll[.Settings] - wheel_y * BROWSE_SCROLL_STEP * app.scale, 0, b.max_scroll[.Settings])
	return true
}

// Over everything else while watching, kept inside `screen`.
draw_settings_window :: proc(app: ^App, screen: Rect) {
	sw := &app.watch.settings_window
	if app.screen != .Watch || !sw.open {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	margin := SETTINGS_WINDOW_MARGIN * scale
	size := SETTINGS_WINDOW_SIZE * scale
	size.x *= r.text_scale
	sw.rect.w = max(min(size.x, screen.w - 2 * margin), 0)
	sw.rect.h = max(min(size.y, screen.h - 2 * margin), 0)
	if !sw.placed {
		sw.placed = true
		sw.rect.x = screen.x + (screen.w - sw.rect.w) / 2
		sw.rect.y = screen.y + (screen.h - sw.rect.h) / 2
	}
	// After a resize, or dragged off the edge: back inside.
	sw.rect.x = clamp(sw.rect.x, screen.x, max(screen.x, screen.x + screen.w - sw.rect.w))
	sw.rect.y = clamp(sw.rect.y, screen.y, max(screen.y, screen.y + screen.h - sw.rect.h))

	hidden := menu_hover_begin(app, sw.rect)
	defer menu_hover_end(app, hidden)
	border := max(1, scale)
	rect := sw.rect
	draw_rect(r, {rect.x - border, rect.y - border, rect.w + 2 * border, rect.h + 2 * border}, USER_CARD_BORDER)
	draw_rect(r, rect, BROWSE_BACKGROUND)
	sw.title = draw_settings(app, rect, floating = true)
	draw_rect(r, {rect.x, sw.title.y + sw.title.h, rect.w, border}, USER_CARD_BORDER)
	draw_language_menu(app, app.browse.language_button, screen)
}

// A stream setting changed (low latency, its buffer, the highest quality, video
// enhancement): while watching, the stream starts again with it once clicks on
// them stop.
settings_stream_changed :: proc(app: ^App) {
	if app.screen == .Watch {
		app.watch.settings_window.restart_at = app.assets.now_ms + SETTINGS_RESTART_MS
	}
}

// Starts the stream again when due. Returns ms until then, for the main loop's
// wait; -1 if nothing's due.
settings_restart_tick :: proc(app: ^App) -> int {
	w := &app.watch
	sw := &w.settings_window
	if sw.restart_at == 0 {
		return -1
	}
	if app.screen != .Watch {
		sw.restart_at = 0
		return -1
	}
	if left := sw.restart_at - app.assets.now_ms; left > 0 {
		return left
	}
	sw.restart_at = 0
	if (w.status == .Playing || w.status == .Starting) && !w.retrying {
		// The qualities are looked up again: the ones above the highest allowed
		// were left out of them.
		delete(w.qualities_page)
		w.qualities_page = ""
		w.qualities = {}
		restart_stream(app)
	}
	return -1
}
