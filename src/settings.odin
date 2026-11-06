package app

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

// The switches on the Settings page.
Setting_Switch :: enum {
	Notifications,
	Update_Checks,
	Low_Latency,
	Follow_Raids,
}

// The Settings page's lists, each with a box to add to it and a button on each
// entry to take it out.
Setting_List :: enum {
	Highlights,
	Ignored,
	Blocked_Channels,
	Blocked_Categories,
}

// Everything that's set once and kept: switches, the text size, the language,
// chat highlights and ignores, what's blocked, and signing out.
Settings_Page :: struct {
	// Where its back button goes.
	back_view:  Browse_View,
	inputs:     [Setting_List]Text_Input,
	box_scroll: [Setting_List]f32,
	// Set while drawing.
	boxes:      [Setting_List]Rect,
	remove:     [Setting_List][dynamic]Rect,
	switches:   [Setting_Switch]Rect,
	smaller:    Rect,
	larger:     Rect,
}

settings_page_destroy :: proc(p: ^Settings_Page) {
	for list in Setting_List {
		input_destroy(&p.inputs[list])
		delete(p.remove[list])
	}
}

browse_open_settings :: proc(app: ^App) {
	b := &app.browse
	if b.view == .Settings {
		return
	}
	if b.view == .Search {
		browse_search_close(app)
	}
	b.settings.back_view = b.view
	b.view = .Settings
	b.hovered = -1
}

settings_back :: proc(app: ^App) {
	b := &app.browse
	settings_unfocus(app)
	b.view = b.settings.back_view
	b.hovered = -1
}

// The add box being typed in, if any.
settings_focused :: proc(b: ^Browse) -> (list: Setting_List, ok: bool) {
	for l in Setting_List {
		if b.settings.inputs[l].focused {
			return l, true
		}
	}
	return {}, false
}

settings_typing :: proc(b: ^Browse) -> bool {
	_, typing := settings_focused(b)
	return typing
}

@(private = "file")
settings_focus :: proc(app: ^App, list: Setting_List) {
	browse_search_unfocus(app)
	settings_unfocus(app)
	app.browse.settings.inputs[list].focused = true
	_ = sdl.StartTextInput(app.window)
}

settings_unfocus :: proc(app: ^App) {
	p := &app.browse.settings
	if _, focused := settings_focused(&app.browse); !focused {
		return
	}
	for list in Setting_List {
		p.inputs[list].focused = false
	}
	_ = sdl.StopTextInput(app.window)
}

settings_text :: proc(app: ^App, text: string) {
	if list, ok := settings_focused(&app.browse); ok {
		input_insert(&app.browse.settings.inputs[list], text)
	}
}

// Keys while typing in an add box: Enter adds what's typed, Esc stops typing.
settings_key :: proc(app: ^App, key: sdl.KeyboardEvent) {
	list, ok := settings_focused(&app.browse)
	if !ok {
		return
	}
	ti := &app.browse.settings.inputs[list]
	switch key.key {
	case sdl.K_ESCAPE:
		settings_unfocus(app)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		if settings_add(app, list, input_text(ti)) {
			input_clear(ti)
		}
	case:
		text_box_key(ti, key)
	}
}

// The entries of `list`.
@(private = "file")
settings_entries :: proc(app: ^App, list: Setting_List) -> []string {
	switch list {
	case .Highlights:
		return app.layout.chat.highlights[:]
	case .Ignored:
		return app.layout.chat.ignored[:]
	case .Blocked_Channels:
		return blocked_list(&app.blocked, .Channel)[:]
	case .Blocked_Categories:
		return blocked_list(&app.blocked, .Category)[:]
	}
	return nil
}

// Adds what was typed in `list`'s box, as the chat commands and the right-click
// menu would. Returns whether it was taken.
settings_add :: proc(app: ^App, list: Setting_List, typed: string) -> bool {
	text := strings.trim_space(typed)
	switch list {
	case .Highlights:
		phrase := strings.to_lower(text, context.temp_allocator)
		if phrase == "" {
			return false
		}
		rule_add(&app.layout.chat.highlights, phrase)
		layout_save(&app.layout)
		return true
	case .Ignored:
		login := strings.to_lower(strings.trim_left(text, "@"), context.temp_allocator)
		if !valid_login(login) {
			return false
		}
		chat_ignore(app, login)
		return true
	case .Blocked_Channels:
		return block(app, .Channel, text)
	case .Blocked_Categories:
		return block(app, .Category, text)
	}
	return false
}

@(private = "file")
settings_remove :: proc(app: ^App, list: Setting_List, i: int) {
	entries := settings_entries(app, list)
	if i < 0 || i >= len(entries) {
		return
	}
	switch list {
	case .Highlights:
		rule_remove(&app.layout.chat.highlights, strings.clone(entries[i], context.temp_allocator))
		layout_save(&app.layout)
	case .Ignored:
		chat_unignore(app, strings.clone(entries[i], context.temp_allocator))
	case .Blocked_Channels:
		unblock(app, .Channel, i)
	case .Blocked_Categories:
		unblock(app, .Category, i)
	}
}

@(private = "file")
setting_on :: proc(app: ^App, s: Setting_Switch) -> bool {
	l := &app.layout
	switch s {
	case .Notifications:
		return !l.notifications_off
	case .Update_Checks:
		return !l.update_checks_off
	case .Low_Latency:
		return l.low_latency
	case .Follow_Raids:
		return !l.raids_off
	}
	return false
}

@(private = "file")
setting_toggle :: proc(app: ^App, s: Setting_Switch) {
	switch s {
	case .Notifications:
		live_notifications_toggle(app)
	case .Update_Checks:
		update_checks_toggle(app)
	case .Low_Latency:
		// Nothing is playing while browsing: the next stream picks it up.
		app.layout.low_latency = !app.layout.low_latency
		layout_save(&app.layout)
	case .Follow_Raids:
		app.layout.raids_off = !app.layout.raids_off
		layout_save(&app.layout)
		watch_listen_for_raids(app)
	}
}

// A left click on the Settings page. Returns true if it hit something.
settings_click :: proc(app: ^App, x, y: f32) -> bool {
	b := &app.browse
	p := &b.settings
	for list in Setting_List {
		if in_rect(p.boxes[list], x, y) {
			settings_focus(app, list)
			return true
		}
	}
	settings_unfocus(app)
	for s in Setting_Switch {
		if in_rect(p.switches[s], x, y) {
			setting_toggle(app, s)
			return true
		}
	}
	if in_rect(p.smaller, x, y) {
		set_text_size(app, app.layout.text_size - TEXT_SIZE_STEP)
		return true
	}
	if in_rect(p.larger, x, y) {
		set_text_size(app, app.layout.text_size + TEXT_SIZE_STEP)
		return true
	}
	for list in Setting_List {
		for rect, i in p.remove[list] {
			if rect.w > 0 && in_rect(rect, x, y) {
				settings_remove(app, list, i)
				return true
			}
		}
	}
	return false
}

// The language row's value: the language, and what's done with the others.
@(private = "file")
language_setting_label :: proc(app: ^App) -> string {
	if app.layout.language == "" {
		return "Any language"
	}
	others := "others hidden" if app.layout.language_hide else "others grayed out"
	return fmt.tprintf("%s, %s", language_name(app.layout.language), others)
}

draw_settings :: proc(app: ^App, content: Rect) {
	r := &app.assets.renderer
	b := &app.browse
	p := &b.settings
	scale := app.scale
	pad := BROWSE_PADDING * scale
	tab_size := BROWSE_TAB_SIZE * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	name_size := BROWSE_CARD_TITLE_SIZE * scale
	lh := line_height(r, .Bold, tab_size)
	heading_h := lh + pad

	// A back button and the heading, like a category's.
	b.back_button = {content.x + pad / 2, content.y + pad / 2, 36 * scale * r.text_scale, heading_h}
	if in_rect(b.back_button, app.mouse.x, app.mouse.y) {
		draw_rect(r, b.back_button, BROWSE_CARD_HOVER)
	}
	draw_centered(r, .Bold, tab_size * 1.6, b.back_button, "‹", BROWSE_TEXT)
	draw_text(r, .Bold, tab_size, b.back_button.x + b.back_button.w + 8 * scale, content.y + pad / 2 + (heading_h - lh) / 2, "Settings", BROWSE_TEXT)
	top := content.y + pad / 2 + heading_h
	rest := Rect{content.x, top, content.w, content.y + content.h - top}

	box_h := line_height(r, .Regular, CHAT_FONT_SIZE * scale) + 2 * CHAT_PADDING * scale
	lh_name := line_height(r, .Bold, name_size)
	lh_text := line_height(r, .Regular, text_size)
	row_pad := 8 * scale
	row_h := max(lh_name, box_h) + 2 * row_pad
	entry_h := lh_name + 2 * row_pad
	row_gap := 4 * scale
	section_gap := 2 * pad
	list_w := min(rest.w - 2 * pad, BROWSE_RESULTS_WIDTH * scale * r.text_scale)
	box_w := min(list_w / 2, BROWSE_SEARCH_WIDTH * scale * r.text_scale)

	switch_labels := [Setting_Switch]string {
		.Notifications = "Notify when a channel you follow goes live",
		.Update_Checks = "Check for new versions",
		.Low_Latency   = "Low latency",
		.Follow_Raids  = "Follow raids to the raided channel",
	}
	lists := [Setting_List]struct {
		label, hint, none: string,
	} {
		.Highlights         = {"Highlight phrases", "Add a word or phrase", "Only mentions of you are highlighted."},
		.Ignored            = {"Ignored users", "Add a login", "No one is ignored."},
		.Blocked_Channels   = {"Channels", "Block a channel by its login", "No channels blocked."},
		.Blocked_Categories = {"Categories", "Block a category by its name", "No categories blocked."},
	}
	Section :: struct {
		title:    string,
		switches: []Setting_Switch,
		lists:    []Setting_List,
		// The text size, the language and the account rows.
		text_size, language, account: bool,
	}
	sections := [?]Section {
		{title = "General", switches = {.Notifications, .Update_Checks}, text_size = true},
		{title = "Streams", switches = {.Low_Latency, .Follow_Raids}, language = true},
		{title = "Chat", lists = {.Highlights, .Ignored}},
		{title = "Blocked", lists = {.Blocked_Channels, .Blocked_Categories}},
		{title = "Account", account = true},
	}

	// The height first, for scrolling.
	total_h := pad
	for s in sections {
		total_h += lh + row_gap
		total_h += f32(len(s.switches) + int(s.text_size) + int(s.language) + int(s.account)) * (row_h + row_gap)
		for list in s.lists {
			n := len(settings_entries(app, list))
			total_h += row_h + row_gap + (f32(n) * (entry_h + row_gap) if n > 0 else lh_text + row_gap)
		}
		total_h += section_gap
	}
	total_h += lh_text + pad
	scroll := &b.scroll[.Settings]
	b.max_scroll[.Settings] = max(0, total_h - rest.h)
	scroll^ = clamp(scroll^, 0, b.max_scroll[.Settings])

	p.switches = {}
	p.smaller, p.larger = {}, {}
	// The language menu opens below it (browse_click, draw_language_menu).
	b.language_button = {}
	app.sign_in.sign_out = {}
	visible :: proc(rect, area: Rect) -> bool {
		return rect.y + rect.h >= area.y && rect.y <= area.y + area.h
	}

	clip_begin(r, rest)
	x := rest.x + pad
	y := rest.y + pad - scroll^
	for s in sections {
		draw_text(r, .Bold, tab_size, x, y, s.title, BROWSE_TEXT)
		y += lh + row_gap

		for sw in s.switches {
			row := Rect{x, y, list_w, row_h}
			y += row_h + row_gap
			draw_rect(r, row, BROWSE_PLACEHOLDER)
			draw_text(r, .Regular, name_size, row.x + row_pad, row.y + (row.h - lh_name) / 2, switch_labels[sw], BROWSE_TEXT)
			rect := draw_switch(app, row.x + row.w - row_pad, row.y + row.h / 2, setting_on(app, sw))
			if visible(row, rest) {
				p.switches[sw] = rect
			}
		}

		if s.text_size {
			row := Rect{x, y, list_w, row_h}
			y += row_h + row_gap
			draw_rect(r, row, BROWSE_PLACEHOLDER)
			draw_text(r, .Regular, name_size, row.x + row_pad, row.y + (row.h - lh_name) / 2, "Text size", BROWSE_TEXT)
			bh := line_height(r, .Bold, text_size) + 12 * scale
			bw := bh * 1.4
			right := row.x + row.w - row_pad
			larger := Rect{right - bw, row.y + (row.h - bh) / 2, bw, bh}
			value := fmt.tprintf("%d%%", app.layout.text_size)
			vw := text_width(r, .Bold, text_size, "200%") + 16 * scale
			smaller := Rect{larger.x - vw - bw, larger.y, bw, bh}
			for button, i in ([2]Rect{smaller, larger}) {
				hovered := in_rect(button, app.mouse.x, app.mouse.y)
				draw_rect(r, button, SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON)
				draw_centered(r, .Bold, text_size, button, "−" if i == 0 else "+", BROWSE_TEXT)
			}
			draw_centered(r, .Bold, text_size, {smaller.x + bw, larger.y, vw, bh}, value, BROWSE_TEXT)
			if visible(row, rest) {
				p.smaller, p.larger = smaller, larger
			}
		}

		if s.language {
			row := Rect{x, y, list_w, row_h}
			y += row_h + row_gap
			draw_rect(r, row, BROWSE_PLACEHOLDER)
			draw_text(r, .Regular, name_size, row.x + row_pad, row.y + (row.h - lh_name) / 2, "Primary language", BROWSE_TEXT)
			label := language_setting_label(app)
			lw := text_width(r, .Regular, text_size, label)
			button := Rect{row.x + row.w - row_pad - lw, row.y + (row.h - lh_text) / 2, lw, lh_text}
			hovered := in_rect(button, app.mouse.x, app.mouse.y) || b.language_menu.open
			draw_text(r, .Regular, text_size, button.x, button.y, label, BROWSE_TEXT if hovered else BROWSE_ACCENT)
			if visible(row, rest) {
				b.language_button = button
			}
		}

		for list in s.lists {
			l := lists[list]
			row := Rect{x, y, list_w, row_h}
			y += row_h + row_gap
			draw_text(r, .Regular, name_size, row.x, row.y + (row.h - lh_name) / 2, l.label, BROWSE_TEXT)
			p.boxes[list] = {row.x + row.w - box_w, row.y + (row.h - box_h) / 2, box_w, box_h}
			draw_text_box(app, &p.inputs[list], &p.box_scroll[list], p.boxes[list], l.hint)
			if !visible(p.boxes[list], rest) {
				p.boxes[list] = {}
			}
			entries := settings_entries(app, list)
			resize(&p.remove[list], len(entries))
			if len(entries) == 0 {
				draw_text(r, .Regular, text_size, x + row_pad, y, l.none, BROWSE_DIM_TEXT)
				y += lh_text + row_gap
			}
			for name, i in entries {
				entry := Rect{x, y, list_w, entry_h}
				y += entry_h + row_gap
				p.remove[list][i] = {}
				if !visible(entry, rest) {
					continue
				}
				label := "Unblock" if list == .Blocked_Channels || list == .Blocked_Categories else "Remove"
				button := remove_button(app, entry, label)
				p.remove[list][i] = button
				draw_rect(r, entry, BROWSE_PLACEHOLDER)
				hovered := in_rect(button, app.mouse.x, app.mouse.y)
				draw_rect(r, button, SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON)
				draw_centered(r, .Bold, text_size, button, label, BROWSE_TEXT)
				tw := button.x - 12 * scale - (entry.x + row_pad)
				draw_text(r, .Bold, name_size, entry.x + row_pad, entry.y + row_pad, fit_text(r, .Bold, name_size, name, tw), BROWSE_TEXT)
			}
		}

		if s.account {
			row := Rect{x, y, list_w, row_h}
			y += row_h + row_gap
			draw_rect(r, row, BROWSE_PLACEHOLDER)
			draw_text(r, .Regular, name_size, row.x + row_pad, row.y + (row.h - lh_name) / 2, fmt.tprintf("Signed in as %s", app.auth.login), BROWSE_TEXT)
			button := remove_button(app, row, "Sign out")
			hovered := in_rect(button, app.mouse.x, app.mouse.y)
			draw_rect(r, button, SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON)
			draw_centered(r, .Bold, text_size, button, "Sign out", BROWSE_TEXT)
			if visible(row, rest) {
				app.sign_in.sign_out = button
			}
		}
		y += section_gap
	}
	draw_text(r, .Regular, text_size, x, y, "Right-click a stream, channel or category to block it.", BROWSE_DIM_TEXT)
	clip_end(r)
}

// A button at the right end of `row`.
@(private = "file")
remove_button :: proc(app: ^App, row: Rect, label: string) -> Rect {
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	bw := text_width(r, .Bold, size, label) + 24 * scale
	bh := line_height(r, .Bold, size) + 12 * scale
	return {row.x + row.w - 8 * scale - bw, row.y + (row.h - bh) / 2, bw, bh}
}

// An on/off switch with its right edge at `right`, centred on `mid_y`: a track
// with a knob at the right when on. Returns where it is.
@(private = "file")
draw_switch :: proc(app: ^App, right, mid_y: f32, on: bool) -> Rect {
	r := &app.assets.renderer
	scale := app.scale
	h := line_height(r, .Bold, BROWSE_CARD_TEXT_SIZE * scale) + 4 * scale
	w := 2 * h
	track := Rect{right - w, mid_y - h / 2, w, h}
	hovered := in_rect(track, app.mouse.x, app.mouse.y)
	color := SIGN_IN_BUTTON if on else USER_CARD_BORDER
	if hovered {
		color = SIGN_IN_BUTTON_HOVER if on else MENU_HOVER
	}
	draw_rect(r, track, color)
	inset := 3 * scale
	knob := h - 2 * inset
	kx := track.x + track.w - inset - knob if on else track.x + inset
	draw_rect(r, {kx, track.y + inset, knob, knob}, BROWSE_TEXT)
	return track
}
