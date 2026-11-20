package app

import "core:fmt"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

// The switches on the Settings page.
Setting_Switch :: enum {
	Notifications,
	Update_Checks,
	Low_Latency,
	Follow_Raids,
	Chat_Timestamps,
	Chat_Highlight_Staff,
	Chat_Hide_Bots,
	Chat_Alternate_Lines,
	Chat_Sync,
	Next_Clip,
}

// Settings with a few values, shown as the value; a click moves to the next.
Setting_Choice :: enum {
	Latency_Buffer,
	Max_Quality,
	Notify_For,
	Start_View,
}

// The Settings page's lists, each with a box to add to it and a button on each
// entry to take it out.
Setting_List :: enum {
	Highlights,
	Ignored,
	Blocked_Channels,
	Blocked_Categories,
	// The channels muted, or chosen, for live notifications (Layout.notify_only).
	Notify_Channels,
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
	choices:    [Setting_Choice]Rect,
	smaller:    Rect,
	larger:     Rect,
	copy_log:   Rect,
	log_folder: Rect,
	// When the Copy log button goes back from saying "Copied", in assets.now_ms.
	copied_until: int,
}

LOG_COPIED_MS :: 2000

// When the "Copied" on the Copy log button is due to go, for the main loop.
settings_wait :: proc(app: ^App) -> int {
	left := app.browse.settings.copied_until - app.assets.now_ms
	return left if left > 0 else -1
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
	case .Notify_Channels:
		l := &app.layout
		return l.notify_chosen[:] if l.notify_only else l.notify_muted[:]
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
	case .Notify_Channels:
		login := strings.to_lower(strings.trim_left(text, "@"), context.temp_allocator)
		if !valid_login(login) {
			return false
		}
		if slice.contains(settings_entries(app, list), login) {
			return true
		}
		notify_toggle(app, login)
		return true
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
	case .Notify_Channels:
		notify_toggle(app, strings.clone(entries[i], context.temp_allocator))
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
	case .Chat_Timestamps:
		return l.chat.timestamps
	case .Chat_Highlight_Staff:
		return l.chat.highlight_staff
	case .Chat_Hide_Bots:
		return l.chat.hide_bots
	case .Chat_Alternate_Lines:
		return l.chat.alternate_lines
	case .Chat_Sync:
		return l.chat_sync
	case .Next_Clip:
		return !l.next_clip_off
	}
	return false
}

// The choice's value, as shown.
@(private = "file")
setting_value :: proc(app: ^App, c: Setting_Choice) -> string {
	l := &app.layout
	switch c {
	case .Latency_Buffer:
		if l.latency_buffer_ms == 0 {
			return "None"
		}
		return fmt.tprintf("%d s", l.latency_buffer_ms / 1000)
	case .Max_Quality:
		if l.max_height == 0 {
			return "No limit"
		}
		return fmt.tprintf("%dp", l.max_height)
	case .Notify_For:
		return "Only channels you choose" if app.layout.notify_only else "All followed channels"
	case .Start_View:
		return BROWSE_TAB_LABELS[app.layout.start_view]
	}
	return ""
}

// Moves the choice on to its next value, after the last back to the first.
@(private = "file")
setting_next :: proc(app: ^App, c: Setting_Choice) {
	next :: proc(values: []int, current: int) -> int {
		for v, i in values {
			if v == current {
				return values[(i + 1) % len(values)]
			}
		}
		return values[0]
	}
	l := &app.layout
	switch c {
	case .Latency_Buffer:
		buffers := LOW_LATENCY_BUFFERS
		l.latency_buffer_ms = next(buffers[:], l.latency_buffer_ms)
	case .Max_Quality:
		heights := MAX_HEIGHTS
		l.max_height = next(heights[:], l.max_height)
	case .Notify_For:
		l.notify_only = !l.notify_only
	case .Start_View:
		views := START_VIEWS
		at := 0
		for v, i in views {
			if v == l.start_view {
				at = i
			}
		}
		l.start_view = views[(at + 1) % len(views)]
	}
	// Nothing is playing while browsing: the next stream picks it up.
	layout_save(l)
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
	case .Chat_Timestamps:
		app.layout.chat.timestamps = !app.layout.chat.timestamps
		layout_save(&app.layout)
	case .Chat_Highlight_Staff:
		app.layout.chat.highlight_staff = !app.layout.chat.highlight_staff
		layout_save(&app.layout)
	case .Chat_Hide_Bots:
		app.layout.chat.hide_bots = !app.layout.chat.hide_bots
		layout_save(&app.layout)
	case .Chat_Alternate_Lines:
		app.layout.chat.alternate_lines = !app.layout.chat.alternate_lines
		layout_save(&app.layout)
	case .Chat_Sync:
		app.layout.chat_sync = !app.layout.chat_sync
		layout_save(&app.layout)
	case .Next_Clip:
		app.layout.next_clip_off = !app.layout.next_clip_off
		layout_save(&app.layout)
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
	for c in Setting_Choice {
		if in_rect(p.choices[c], x, y) {
			setting_next(app, c)
			return true
		}
	}
	if in_rect(p.copy_log, x, y) {
		if log_copy() {
			p.copied_until = app.assets.now_ms + LOG_COPIED_MS
		}
		return true
	}
	if in_rect(p.log_folder, x, y) {
		log_open_folder()
		return true
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
		.Chat_Timestamps      = "Show when each message was sent",
		.Chat_Highlight_Staff = "Highlight the streamer's and moderators' messages",
		.Chat_Hide_Bots       = "Hide bots and !commands",
		.Chat_Alternate_Lines = "Alternate message backgrounds",
		.Chat_Sync     = "Delay chat to match the stream",
		.Next_Clip     = "Play the next clip when one ends",
	}
	choice_labels := [Setting_Choice]string {
		.Latency_Buffer = "Low latency buffer",
		.Max_Quality    = "Highest quality",
		.Notify_For     = "Notify for",
		.Start_View     = "Start page",
	}
	lists := [Setting_List]struct {
		label, hint, none: string,
	} {
		.Highlights         = {"Highlight phrases", "Add a word or phrase", "Only mentions of you are highlighted."},
		.Ignored            = {"Ignored users", "Add a login", "No one is ignored."},
		.Blocked_Channels   = {"Channels", "Block a channel by its login", "No channels blocked."},
		.Blocked_Categories = {"Categories", "Block a category by its name", "No categories blocked."},
		.Notify_Channels    = {"Muted channels", "Mute a channel by its login", "No channels muted."},
	}
	if app.layout.notify_only {
		lists[.Notify_Channels] = {"Chosen channels", "Choose a channel by its login", "No channels chosen: none will notify."}
	}
	Section :: struct {
		title:    string,
		switches: []Setting_Switch,
		choices:  []Setting_Choice,
		lists:    []Setting_List,
		// The text size, the language, the account and the log rows.
		text_size, language, account, log: bool,
		// Shown only where there are notifications (NOTIFICATIONS_SUPPORTED).
		notifications: bool,
	}
	general_switches := []Setting_Switch{.Notifications, .Update_Checks} if NOTIFICATIONS_SUPPORTED else []Setting_Switch{.Update_Checks}
	all_sections := [?]Section {
		{title = "General", switches = general_switches, choices = {.Start_View}, text_size = true},
		{title = "Streams", switches = {.Low_Latency, .Follow_Raids, .Next_Clip}, choices = {.Latency_Buffer, .Max_Quality}, language = true},
		{title = "Live notifications", choices = {.Notify_For}, lists = {.Notify_Channels}, notifications = true},
		{title = "Chat", switches = {.Chat_Sync, .Chat_Timestamps, .Chat_Highlight_Staff, .Chat_Hide_Bots, .Chat_Alternate_Lines}, lists = {.Highlights, .Ignored}},
		{title = "Blocked", lists = {.Blocked_Channels, .Blocked_Categories}},
		{title = "Account", account = true},
		{title = "Bug reports", log = true},
	}
	sections := make([dynamic]Section, context.temp_allocator)
	for s in all_sections {
		if NOTIFICATIONS_SUPPORTED || !s.notifications {
			append(&sections, s)
		}
	}

	// The height first, for scrolling.
	total_h := pad
	for s in sections {
		total_h += lh + row_gap
		total_h += f32(len(s.switches) + len(s.choices) + int(s.text_size) + int(s.language) + int(s.account) + int(s.log)) * (row_h + row_gap)
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
	p.choices = {}
	p.smaller, p.larger = {}, {}
	p.copy_log, p.log_folder = {}, {}
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

		for c in s.choices {
			row := Rect{x, y, list_w, row_h}
			y += row_h + row_gap
			draw_rect(r, row, BROWSE_PLACEHOLDER)
			draw_text(r, .Regular, name_size, row.x + row_pad, row.y + (row.h - lh_name) / 2, choice_labels[c], BROWSE_TEXT)
			value := setting_value(app, c)
			vw := text_width(r, .Regular, text_size, value)
			button := Rect{row.x + row.w - row_pad - vw, row.y + (row.h - lh_text) / 2, vw, lh_text}
			hovered := in_rect(button, app.mouse.x, app.mouse.y)
			draw_text(r, .Regular, text_size, button.x, button.y, value, BROWSE_TEXT if hovered else BROWSE_ACCENT)
			if visible(row, rest) {
				p.choices[c] = button
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
		if s.log {
			row := Rect{x, y, list_w, row_h}
			y += row_h + row_gap
			draw_rect(r, row, BROWSE_PLACEHOLDER)
			draw_text(r, .Regular, name_size, row.x + row_pad, row.y + (row.h - lh_name) / 2, fmt.tprintf("Lurker %s's log", APP_VERSION), BROWSE_TEXT)
			copy_label := "Copied" if app.assets.now_ms < p.copied_until else "Copy log"
			folder := remove_button(app, row, "Open log folder")
			// As wide as it is with "Copy log", so it doesn't jump on "Copied".
			copy_w := remove_button(app, row, "Copy log").w
			copy := Rect{folder.x - 8 * scale - copy_w, folder.y, copy_w, folder.h}
			for button, i in ([2]Rect{copy, folder}) {
				hovered := in_rect(button, app.mouse.x, app.mouse.y)
				draw_rect(r, button, SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON)
				draw_centered(r, .Bold, text_size, button, copy_label if i == 0 else "Open log folder", BROWSE_TEXT)
			}
			if visible(row, rest) {
				p.copy_log, p.log_folder = copy, folder
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
