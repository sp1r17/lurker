package app

import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

CHAT_HEADER_HEIGHT :: 30
CHAT_HEADER :: Color{0x1f, 0x1f, 0x23, 255}
CHAT_DIVIDER :: Color{0x0e, 0x0e, 0x10, 255}

// One channel's chat, as a split: its messages, emotes and badges, chat box and
// search. A new split has no channel yet and asks for one in its chat box.
Chat_Pane :: struct {
	// Unique for the run; jobs for a pane carry it, and are dropped if it's gone.
	id:            int,
	// "" while asking which channel to join.
	channel:       string,
	chat:          ^Chat,
	view:          Chat_View,
	// The channel's own emotes and badges.
	emotes:        Emotes,
	// The channel's user ID, once the chat has joined.
	room_id:       string,
	boxes:         [Box]Text_Input,
	// How far each box's text is scrolled to keep the cursor in view, in pixels.
	box_scroll:    [Box]f32,
	// The search box is showing (Ctrl+F); boxes[.Search] filters the chat.
	searching:     bool,
	// From the last draw, in pixels.
	rect:          Rect,
	header_rect:   Rect,
	messages_rect: Rect,
	input_rect:    Rect,
	search_rect:   Rect,
	// The emote picker (emote_picker.odin): the chosen row, the ":word" Esc closed
	// it for (where it starts + 1; 0 for none), and its rows from the last draw.
	picker_selected:  int,
	picker_dismissed: int,
	picker_rows:      [dynamic]Rect,
	// The message being replied to (right-click), shown above the chat box: its ID
	// is "" when not replying. Owned. And from the last draw, the bar and its
	// close button.
	reply:            Chat_Reply,
	reply_rect:       Rect,
	reply_close:      Rect,
	// Messages that mentioned the user while they couldn't see them (see
	// pane_seen), shown as a count on the header; and from the last draw, where.
	unread_mentions:  int,
	mention_badge:    Rect,
}

// The two text boxes in a chat pane.
Box :: enum {
	// Sending messages, at the bottom (or naming the channel, in a new split).
	Chat,
	// Filtering the chat (Ctrl+F), below the header.
	Search,
}

pane_new :: proc(app: ^App) -> ^Chat_Pane {
	app.next_pane_id += 1
	p := new(Chat_Pane)
	p.id = app.next_pane_id
	p.view.emotes = &p.emotes
	return p
}

// Joins `channel`'s chat.
pane_join :: proc(app: ^App, p: ^Chat_Pane, channel: string) {
	p.channel = strings.clone(channel)
	p.chat = new(Chat)
	if app.signed_in {
		chat_start(p.chat, p.channel, app.chat_wake_event, app.auth.login, app.auth.access_token)
	} else {
		chat_start(p.chat, p.channel, app.chat_wake_event)
	}
}

pane_destroy :: proc(app: ^App, p: ^Chat_Pane) {
	if typing, _, ok := focused_box(app); ok && typing == p {
		box_unfocus(app)
	}
	if p.chat != nil {
		chat_stop(p.chat)
		free(p.chat)
	}
	chat_view_destroy(&p.view)
	emotes_destroy(&p.emotes)
	for &ti in p.boxes {
		input_destroy(&ti)
	}
	delete(p.room_id)
	delete(p.channel)
	delete(p.picker_rows)
	pane_reply_cancel(p)
	free(p)
}

// Takes new chat messages. Once the chat has joined, the channel's ID is known:
// loads its emotes and badges.
pane_chat_arrived :: proc(app: ^App, p: ^Chat_Pane) {
	if p.chat == nil {
		return
	}
	arrived := make([dynamic]Chat_Message, context.temp_allocator)
	chat_take(p.chat, &arrived)
	if pane_replaying(app, p) {
		// A past broadcast's chat is showing instead.
		for m in arrived {
			destroy_chat_message(m)
		}
		clear(&arrived)
	}
	if len(arrived) > 0 {
		added := chat_view_add(&p.view, &app.assets, app.scale, pane_text_width(app, p), arrived[:], app.auth.login if app.signed_in else "")
		if !pane_seen(app, p) {
			p.unread_mentions += added
		}
	}
	if p.room_id != "" {
		return
	}
	room_id := chat_room_id(p.chat)
	if room_id == "" {
		return
	}
	p.room_id = strings.clone(room_id)
	for source in Emote_Source.Channel_7TV ..= Emote_Source.Channel_FFZ {
		emotes_request_set(&app.assets.jobs, source, room_id, p.id)
	}
	if app.signed_in {
		emotes_request_badges(&app.assets.jobs, app.client_id, app.auth, room_id, p.id)
	}
}

// Whether new messages in `p` are in front of the user: the window has focus, the
// chats are showing and this one is at its newest messages.
pane_seen :: proc(app: ^App, p: ^Chat_Pane) -> bool {
	return app.window_focused && app.watch.show_chat && p.view.scroll == 0
}

// Whether `p` shows a past broadcast's chat (it's the main chat, during a replay),
// which can't be sent to.
pane_replaying :: proc(app: ^App, p: ^Chat_Pane) -> bool {
	return app.watch.replay.active && len(app.watch.panes) > 0 && app.watch.panes[0] == p
}

// The width messages wrap to.
@(private = "file")
pane_text_width :: proc(app: ^App, p: ^Chat_Pane) -> f32 {
	return p.messages_rect.w - 2 * CHAT_PADDING * app.scale
}

pane_layout :: proc(app: ^App, p: ^Chat_Pane, rect: Rect) {
	scale := app.scale
	pad := CHAT_PADDING * scale
	box_h := line_height(&app.assets.renderer, .Regular, CHAT_FONT_SIZE * scale) + 2 * pad
	p.rect = rect
	// Taller than CHAT_HEADER_HEIGHT if the text size needs it.
	title_h := line_height(&app.assets.renderer, .Bold, BROWSE_CARD_TEXT_SIZE * scale) + 8 * scale
	p.header_rect = {rect.x, rect.y, rect.w, max(CHAT_HEADER_HEIGHT * scale, title_h)}
	top := p.header_rect.y + p.header_rect.h
	if p.searching {
		p.search_rect = {rect.x + pad, top + pad, rect.w - 2 * pad, box_h}
		top = p.search_rect.y + p.search_rect.h
	} else {
		p.search_rect = {}
	}
	p.input_rect = {rect.x + pad, rect.y + rect.h - pad - box_h, rect.w - 2 * pad, box_h}
	bottom := p.input_rect.y - pad
	p.reply_rect = {}
	if p.reply.id != "" {
		reply_h := line_height(&app.assets.renderer, .Regular, CHAT_FONT_SIZE * scale) + pad
		p.reply_rect = {p.input_rect.x, p.input_rect.y - reply_h, p.input_rect.w, reply_h}
		bottom = p.reply_rect.y - pad / 2
	}
	p.messages_rect = {rect.x, top, rect.w, bottom - top}
}

draw_pane :: proc(app: ^App, p: ^Chat_Pane, focused: bool) {
	a := &app.assets
	r := &a.renderer
	scale := app.scale
	draw_rect(r, p.rect, CHAT_BACKGROUND)
	if pane_seen(app, p) {
		p.unread_mentions = 0
	}

	// Header: the channel, with an accent line on the focused split, and how many
	// mentions are unread at its right.
	draw_rect(r, p.header_rect, CHAT_HEADER)
	title := p.channel if p.channel != "" else "New split"
	size := BROWSE_CARD_TEXT_SIZE * scale
	p.mention_badge = {}
	title_room := p.header_rect.w - 16 * scale
	if p.unread_mentions > 0 {
		p.mention_badge = draw_mention_badge(app, p.header_rect.x + p.header_rect.w - 6 * scale, p.header_rect.y + p.header_rect.h / 2, p.unread_mentions)
		// The title stays centred, clear of the badge.
		title_room = 2 * (p.mention_badge.x - p.header_rect.x - p.header_rect.w / 2) - 8 * scale
	}
	draw_centered(r, .Bold, size, p.header_rect, fit_text(r, .Bold, size, title, title_room), CHAT_TEXT)
	if focused && len(app.watch.panes) > 1 {
		h := p.header_rect
		draw_rect(r, {h.x, h.y + h.h - 2 * scale, h.w, 2 * scale}, BROWSE_ACCENT)
	}

	filter := input_text(&p.boxes[.Search]) if p.searching else ""
	if p.channel == "" {
		draw_centered(r, .Regular, CHAT_FONT_SIZE * scale, p.messages_rect, "Which channel?", CHAT_SYSTEM_TEXT)
	} else {
		draw_chat_view(a, &p.view, p.messages_rect, scale, filter)
	}

	hint := "Channel name, then Enter (Esc to cancel)"
	if p.channel != "" {
		hint = "Send a message (Enter)" if app.signed_in else "Sign in to chat"
		if p.reply.id != "" {
			hint = "Reply (Enter, or Esc to cancel)"
		}
		if pane_replaying(app, p) {
			hint = "Chat replay: sending is off"
		}
	}
	draw_reply_bar(app, p)
	draw_box(app, p, .Chat, p.input_rect, hint)
	draw_emote_picker(app, p)
	if p.searching {
		draw_box(app, p, .Search, p.search_rect, "" if filter != "" else "Search, or from:name")
		if filter != "" {
			// Match count at the box's right edge.
			count := fmt.tprintf("%d found", p.view.matches)
			cw := text_width(r, .Regular, size, count)
			pad := CHAT_PADDING * scale
			ch := line_height(r, .Regular, size)
			sr := p.search_rect
			draw_rect(r, {sr.x + sr.w - cw - 2 * pad, sr.y + 2 * scale, cw + 2 * pad - 2 * scale, sr.h - 4 * scale}, INPUT_BACKGROUND)
			draw_text(r, .Regular, size, sr.x + sr.w - cw - pad, sr.y + (sr.h - ch) / 2, count, CHAT_SYSTEM_TEXT)
		}
	}
}

// A text box: what's typed, or a hint, with a cursor while focused.
@(private = "file")
draw_box :: proc(app: ^App, p: ^Chat_Pane, box: Box, rect: Rect, hint: string) {
	draw_text_box(app, &p.boxes[box], &p.box_scroll[box], rect, hint)
}

// A one-line text field in `rect`, `hint` showing while it's empty and unfocused.
// `scroll` keeps the cursor in view between frames.
draw_text_box :: proc(app: ^App, ti: ^Text_Input, scroll: ^f32, rect: Rect, hint: string) {
	r := &app.assets.renderer
	scale := app.scale
	size := CHAT_FONT_SIZE * scale
	pad := CHAT_PADDING * scale
	if ti.focused {
		draw_rect(r, rect, BROWSE_ACCENT)
		draw_rect(r, {rect.x + 2 * scale, rect.y + 2 * scale, rect.w - 4 * scale, rect.h - 4 * scale}, INPUT_BACKGROUND)
	} else {
		draw_rect(r, rect, INPUT_BACKGROUND)
	}

	text := input_text(ti)
	inner := Rect{rect.x + pad, rect.y, rect.w - 2 * pad, rect.h}
	ty := rect.y + pad
	if text == "" && !ti.focused {
		draw_text(r, .Regular, size, inner.x, ty, fit_text(r, .Regular, size, hint, inner.w), CHAT_SYSTEM_TEXT)
		return
	}
	// Scroll so the cursor stays inside the box.
	cursor_x := text_width(r, .Regular, size, text[:ti.cursor])
	if cursor_x - scroll^ > inner.w - 2 * scale {
		scroll^ = cursor_x - inner.w + 2 * scale
	} else if cursor_x < scroll^ {
		scroll^ = cursor_x
	}
	clip_begin(r, inner)
	if lo, hi := input_selection(ti); lo != hi && ti.focused {
		x0 := text_width(r, .Regular, size, text[:lo])
		x1 := text_width(r, .Regular, size, text[:hi])
		draw_rect(r, {inner.x + x0 - scroll^, ty, x1 - x0, line_height(r, .Regular, size)}, SELECTION_BACKGROUND)
	}
	draw_text(r, .Regular, size, inner.x - scroll^, ty, text, CHAT_TEXT)
	if ti.focused {
		draw_rect(r, {inner.x + cursor_x - scroll^, ty, 2 * scale, line_height(r, .Regular, size)}, CHAT_TEXT)
	}
	clip_end(r)
}

// The box being typed in, if any.
focused_box :: proc(app: ^App) -> (p: ^Chat_Pane, box: Box, ok: bool) {
	for pane in app.watch.panes {
		for ti, b in pane.boxes {
			if ti.focused {
				return pane, b, true
			}
		}
	}
	return nil, {}, false
}

box_focus :: proc(app: ^App, p: ^Chat_Pane, box: Box) {
	if !app.watch.show_chat {
		return
	}
	// Chatting needs a sign-in; naming a new split's channel doesn't. A replayed
	// chat can't be sent to.
	if box == .Chat && p.channel != "" && (!app.signed_in || pane_replaying(app, p)) {
		return
	}
	if current, current_box, typing := focused_box(app); typing {
		if current == p && current_box == box {
			return
		}
		current.boxes[current_box].focused = false
	} else if !sdl.StartTextInput(app.window) {
		log.warnf("can't start text input, so typing won't work: %s", sdl.GetError())
	}
	p.boxes[box].focused = true
}

box_unfocus :: proc(app: ^App) {
	if p, box, typing := focused_box(app); typing {
		p.boxes[box].focused = false
		_ = sdl.StopTextInput(app.window)
	}
}

search_open :: proc(app: ^App, p: ^Chat_Pane) {
	if p.channel == "" {
		return
	}
	p.searching = true
	box_focus(app, p, .Search)
}

search_close :: proc(app: ^App, p: ^Chat_Pane) {
	if p.boxes[.Search].focused {
		box_unfocus(app)
	}
	p.searching = false
	input_clear(&p.boxes[.Search])
	p.view.scroll = 0
}

// Handles a click inside the pane.
pane_click :: proc(app: ^App, p: ^Chat_Pane, x, y: f32) {
	if emote_picker_click(app, p, x, y) {
		return
	}
	// Back to the newest messages, which marks the mentions read.
	if p.mention_badge.w > 0 && in_rect(p.mention_badge, x, y) {
		p.view.scroll = 0
		return
	}
	if p.reply_close.w > 0 && in_rect(p.reply_close, x, y) {
		pane_reply_cancel(p)
		return
	}
	if p.reply_rect.w > 0 && in_rect(p.reply_rect, x, y) {
		box_focus(app, p, .Chat)
		return
	}
	if in_rect(p.input_rect, x, y) {
		box_focus(app, p, .Chat)
		return
	}
	if p.searching && in_rect(p.search_rect, x, y) {
		box_focus(app, p, .Search)
		return
	}
	box_unfocus(app)
	if url, found := chat_view_link_at(&p.view, x, y); found {
		if !sdl.OpenURL(strings.clone_to_cstring(url, context.temp_allocator)) {
			log.warnf("can't open %s: %s", url, sdl.GetError())
		}
		return
	}
	if login, found := chat_view_name_at(&p.view, x, y); found {
		user_card_open(app, p, login, y)
		return
	}
	user_card_close(app)
	chat_view_click(&p.view, x, y)
}

pane_text_input :: proc(app: ^App, text: string) {
	if p, box, typing := focused_box(app); typing {
		input_insert(&p.boxes[box], text)
		p.picker_selected = 0
		if box == .Search {
			p.view.scroll = 0
		}
	}
}

// Keys while typing in a box.
pane_input_key :: proc(app: ^App, key: sdl.KeyboardEvent) {
	p, box, typing := focused_box(app)
	if !typing {
		return
	}
	ti := &p.boxes[box]
	if box == .Chat && emote_picker_key(app, p, key) {
		return
	}
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}
	before := len(ti.text)
	switch key.key {
	case sdl.K_ESCAPE:
		switch {
		case box == .Chat && p.reply.id != "":
			// Stops replying, still typing.
			pane_reply_cancel(p)
		case box == .Search:
			search_close(app, p)
		case p.channel == "":
			watch_close_pane(app, p)
			return
		case:
			box_unfocus(app)
		}
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		switch {
		case box == .Search:
			// Keep the filter, and the keys for the player.
			box_unfocus(app)
		case p.channel == "":
			pane_submit_channel(app, p)
		case:
			pane_send(app, p)
		}
	case sdl.K_F:
		if ctrl {
			search_open(app, p)
		}
	case sdl.K_TAB:
		emote_names, user_names := completion_names(app, p)
		input_complete(ti, emote_names, user_names, backwards = shift)
	case sdl.K_W:
		if ctrl {
			watch_close_pane(app, p)
			return
		}
	case:
		text_box_key(ti, key)
	}
	if len(ti.text) != before {
		p.picker_selected = 0
		if box == .Search {
			p.view.scroll = 0
		}
	}
}

// The editing keys every text box shares: deleting, moving (by word with Ctrl,
// selecting with Shift), and Ctrl+A, C, X and V. Returns true if the key was one.
text_box_key :: proc(ti: ^Text_Input, key: sdl.KeyboardEvent) -> bool {
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}
	by: Input_Move = .Word if ctrl else .Char
	switch key.key {
	case sdl.K_BACKSPACE:
		input_delete(ti, by)
	case sdl.K_DELETE:
		input_delete(ti, by, forward = true)
	case sdl.K_LEFT:
		input_move(ti, by, forward = false, extend = shift)
	case sdl.K_RIGHT:
		input_move(ti, by, forward = true, extend = shift)
	case sdl.K_HOME:
		input_move(ti, .Line, forward = false, extend = shift)
	case sdl.K_END:
		input_move(ti, .Line, forward = true, extend = shift)
	case sdl.K_A:
		if !ctrl {
			return false
		}
		input_select_all(ti)
	case sdl.K_C, sdl.K_X:
		if !ctrl {
			return false
		}
		if input_selected_text(ti) != "" {
			copy_text(input_selected_text(ti))
			if key.key == sdl.K_X {
				input_delete(ti, .Char)
			}
		}
	case sdl.K_V:
		if !ctrl {
			return false
		}
		paste(ti)
	case:
		return false
	}
	return true
}

// A new split's chat box holds the channel to join.
@(private = "file")
pane_submit_channel :: proc(app: ^App, p: ^Chat_Pane) {
	name := strings.to_lower(strings.trim_space(input_text(&p.boxes[.Chat])), context.temp_allocator)
	name = strings.trim_left(name, "#")
	if !valid_login(name) {
		return
	}
	input_clear(&p.boxes[.Chat])
	box_unfocus(app)
	pane_join(app, p, name)
	layout_remember(app)
}

@(private = "file")
copy_text :: proc(text: string) {
	if !sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator)) {
		log.warnf("can't copy: %s", sdl.GetError())
	}
}

// Pastes the clipboard, as one line.
@(private = "file")
paste :: proc(ti: ^Text_Input) {
	raw := sdl.GetClipboardText()
	if raw == nil {
		return
	}
	defer sdl.free(raw)
	text := string(cstring(raw))
	text, _ = strings.replace_all(text, "\r\n", " ", context.temp_allocator)
	text, _ = strings.replace_all(text, "\n", " ", context.temp_allocator)
	input_insert(ti, text)
}

// Names Tab can complete: the user's Twitch emotes, the channel's and global
// third-party emotes, and everyone who has
// talked in this chat. Allocated with the temp allocator.
@(private = "file")
completion_names :: proc(app: ^App, p: ^Chat_Pane) -> (emote_names, user_names: []string) {
	emotes := make([dynamic]string, context.temp_allocator)
	for name, e in app.assets.user_emotes {
		if user_emote_usable(e, p.channel) {
			append(&emotes, name)
		}
	}
	for e in ([]^Emotes{&p.emotes, &app.assets.emotes}) {
		for &set in e.sets {
			for name in set {
				append(&emotes, name)
			}
		}
	}
	users := make([dynamic]string, context.temp_allocator)
	for m in p.view.messages {
		if m.kind == .System || m.name == "" {
			continue
		}
		// Names like "이름 (login)" complete as the login.
		name := m.name
		if open := strings.index(name, " ("); open >= 0 {
			name = strings.trim_suffix(name[open + 2:], ")")
		}
		append(&users, name)
	}
	return emotes[:], users[:]
}

// Sends what's typed. "/me" is the only command: Twitch's IRC no longer runs the
// others.
@(private = "file")
pane_send :: proc(app: ^App, p: ^Chat_Pane) {
	w := &app.watch
	text := strings.trim_space(input_text(&p.boxes[.Chat]))
	if text == "" {
		return
	}
	line := text
	if strings.has_prefix(text, "/me ") {
		line = strings.concatenate({"\x01ACTION ", text[len("/me "):], "\x01"}, context.temp_allocator)
	} else if strings.has_prefix(text, "/") {
		notice(app, p, "Only /me works here so far.")
		return
	}

	// Twitch's limit counts every channel the account chats in.
	now := app.assets.now_ms
	for len(w.sent_at) > 0 && now - w.sent_at[0] > CHAT_RATE_WINDOW_MS {
		ordered_remove(&w.sent_at, 0)
	}
	if len(w.sent_at) >= CHAT_RATE_LIMIT {
		notice(app, p, "Slow down: Twitch allows 20 messages every 30 seconds.")
		return
	}
	append(&w.sent_at, now)
	if p.reply.id != "" && !strings.has_prefix(line, "\x01") {
		// As twitch.tv does, for chats that don't show replies.
		mention := strings.concatenate({"@", p.reply.name, " "}, context.temp_allocator)
		if !strings.has_prefix(strings.to_lower(line, context.temp_allocator), strings.to_lower(mention, context.temp_allocator)) {
			line = strings.concatenate({mention, line}, context.temp_allocator)
		}
	}
	chat_send(p.chat, line, p.reply)
	pane_reply_cancel(p)
	input_clear(&p.boxes[.Chat])
}

// Starts a reply to `m` (on a right-click), if it can have one: it's from
// someone else, with an ID, and there's a sign-in to chat with.
pane_reply_start :: proc(app: ^App, p: ^Chat_Pane, m: ^Chat_Message) {
	if pane_replaying(app, p) || !app.signed_in || p.channel == "" || m.id == "" || m.kind == .System || m.deleted {
		return
	}
	pane_reply_cancel(p)
	name := m.name
	// "이름 (login)" replies as the login, which everyone can read.
	if open := strings.index(name, " ("); open >= 0 {
		name = m.login
	}
	body := strings.builder_make(context.temp_allocator)
	for f in m.fragments {
		if strings.builder_len(body) > 0 && !f.attached {
			strings.write_byte(&body, ' ')
		}
		strings.write_string(&body, strings.trim_space(f.text))
	}
	p.reply = {
		id    = strings.clone(m.id),
		login = strings.clone(m.login),
		name  = strings.clone(name),
		body  = strings.clone(strings.to_string(body)),
	}
	box_focus(app, p, .Chat)
}

pane_reply_cancel :: proc(p: ^Chat_Pane) {
	delete(p.reply.id)
	delete(p.reply.login)
	delete(p.reply.name)
	delete(p.reply.body)
	p.reply = {}
}

// "Replying to @name: their message" above the chat box, with × to stop.
@(private = "file")
draw_reply_bar :: proc(app: ^App, p: ^Chat_Pane) {
	p.reply_close = {}
	if p.reply.id == "" || p.reply_rect.w == 0 {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := CHAT_FONT_SIZE * scale
	pad := CHAT_PADDING * scale
	bar := p.reply_rect
	draw_rect(r, bar, CHAT_HEADER)
	draw_rect(r, {bar.x, bar.y, 3 * scale, bar.h}, BROWSE_ACCENT)
	p.reply_close = {bar.x + bar.w - bar.h, bar.y, bar.h, bar.h}
	if in_rect(p.reply_close, app.mouse.x, app.mouse.y) {
		draw_rect(r, p.reply_close, MENU_HOVER)
	}
	draw_centered(r, .Bold, size, p.reply_close, "×", CHAT_TEXT)
	lh := line_height(r, .Regular, size)
	label := fmt.tprintf("Replying to @%s: %s", p.reply.name, p.reply.body)
	tx := bar.x + pad
	draw_text(r, .Regular, size, tx, bar.y + (bar.h - lh) / 2, fit_text(r, .Regular, size, label, p.reply_close.x - tx - pad / 2), CHAT_SYSTEM_TEXT)
}

// Shows a message from the app in the pane's chat.
@(private = "file")
notice :: proc(app: ^App, p: ^Chat_Pane, text: string) {
	messages := []Chat_Message{system_message(text)}
	chat_view_add(&p.view, &app.assets, app.scale, pane_text_width(app, p), messages)
}

MENTION_BADGE :: Color{0xd0, 0x3a, 0x5c, 255}

// "@3": a count of unread mentions with its right edge at `right`, centred on
// `mid_y`. Returns where it is.
draw_mention_badge :: proc(app: ^App, right, mid_y: f32, count: int) -> Rect {
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	label := fmt.tprintf("@%d", count) if count < 100 else "@99+"
	w := text_width(r, .Bold, size, label) + 12 * scale
	h := line_height(r, .Bold, size) + 2 * scale
	badge := Rect{right - w, mid_y - h / 2, w, h}
	draw_rect(r, badge, MENTION_BADGE)
	draw_centered(r, .Bold, size, badge, label, BROWSE_TEXT)
	return badge
}
