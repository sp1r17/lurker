package app

import "core:strings"
import sdl "vendor:sdl3"

// The keyboard shortcut list (?): over everything, on either screen, until
// Esc, ? or a click. The same as the README's table, which a test checks.

Shortcut :: struct {
	keys, action: string,
}

SHORTCUTS :: [?]Shortcut {
	{"Space", "Pause"},
	{"M", "Mute"},
	{"Up / Down", "Volume"},
	{"Left / Right", "Seek 10 seconds (videos)"},
	{"[ / ]", "Slower / faster (videos)"},
	{", / .", "A frame back / on, paused (videos)"},
	{"Page Up / Page Down", "Previous / next chapter"},
	{"Home", "Start a resumed video over"},
	{"F", "Fullscreen"},
	{"Double-click the video or the top bar", "Fullscreen / back"},
	{"C", "Show or hide chat"},
	{"O", "Chat over the video, or beside it"},
	{"I", "Show or hide the stream stats"},
	{"S", "Screenshot of the video, saved in Pictures/Lurker"},
	{"R", "Refresh (or start a frozen stream again)"},
	{"Enter", "Chat in the focused split, or play an offline channel's last broadcast"},
	{"Ctrl+T / Ctrl+W", "Open / close a chat split"},
	{"Ctrl+,", "Settings (when browsing)"},
	{"Ctrl+F", "Search the chat, or channels when browsing"},
	{"/", "Search channels"},
	{"Ctrl+= / Ctrl+- / Ctrl+0, or Ctrl+scroll", "Text size"},
	{"Esc, or the mouse's back button", "Back"},
	{"?", "This list, in the app"},
	{"Q", "Quit"},
}

// Whether `key` is "?": its own key on some layouts, Shift+/ on most.
is_question_key :: proc(key: sdl.KeyboardEvent) -> bool {
	return key.key == sdl.K_QUESTION || (key.key == sdl.K_SLASH && key.mod & sdl.KMOD_SHIFT != {})
}

// A key while the list is open: Esc or ? closes it; nothing else does anything.
shortcuts_key :: proc(app: ^App, key: sdl.KeyboardEvent) {
	if key.key == sdl.K_ESCAPE || is_question_key(key) {
		app.shortcuts_open = false
	}
}

// The list, centred over a dimmed screen, in two columns: the keys and what
// they do.
draw_shortcuts :: proc(app: ^App, screen: Rect) {
	if !app.shortcuts_open {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	title_size := BROWSE_TAB_SIZE * scale
	pad := 20 * scale
	gap := 24 * scale
	lh := line_height(r, .Regular, size) + 4 * scale
	title_h := line_height(r, .Bold, title_size) + 12 * scale
	list := SHORTCUTS
	keys_w, action_w: f32
	for s in list {
		keys_w = max(keys_w, text_width(r, .Bold, size, shortcut_keys(s.keys)))
		action_w = max(action_w, text_width(r, .Regular, size, s.action))
	}
	w := min(keys_w + gap + action_w + 2 * pad, screen.w - 32 * scale)
	h := min(title_h + f32(len(list)) * lh + 2 * pad, screen.h - 32 * scale)
	panel := Rect{screen.x + (screen.w - w) / 2, screen.y + (screen.h - h) / 2, w, h}
	draw_rect(r, screen, {0, 0, 0, 128})
	// Opaque: what's behind would show through the text.
	draw_rect(r, panel, {CHAT_TOGGLE_BACKGROUND.r, CHAT_TOGGLE_BACKGROUND.g, CHAT_TOGGLE_BACKGROUND.b, 255})
	clip_begin(r, panel)
	draw_text(r, .Bold, title_size, panel.x + pad, panel.y + pad, "Keyboard shortcuts", BROWSE_TEXT)
	action_x := panel.x + pad + keys_w + gap
	for s, i in list {
		y := panel.y + pad + title_h + f32(i) * lh
		draw_text(r, .Bold, size, panel.x + pad, y, shortcut_keys(s.keys), BROWSE_TEXT)
		draw_text(r, .Regular, size, action_x, y, fit_text(r, .Regular, size, s.action, panel.x + panel.w - pad - action_x), BROWSE_DIM_TEXT)
	}
	clip_end(r)
}

// `keys` as they're pressed here: Cmd for Ctrl on macOS. Allocated with the
// temp allocator.
shortcut_keys :: proc(keys: string) -> string {
	if ODIN_OS != .Darwin {
		return keys
	}
	out, _ := strings.replace_all(keys, "Ctrl+", "Cmd+", context.temp_allocator)
	return out
}
