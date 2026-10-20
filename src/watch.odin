package app

import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

// Twitch's limit for ordinary chatters; going over locks the account out of chat
// for 30 minutes, so the app refuses first.
CHAT_RATE_LIMIT :: 20
CHAT_RATE_WINDOW_MS :: 30_000
INPUT_BACKGROUND :: Color{0x26, 0x26, 0x2c, 255}

Stream_Status :: enum {
	// Asking streamlink for the stream's URL.
	Resolving,
	Playing,
	Offline,
	Failed,
}

// Watching one channel: its video and its chat.
Watch :: struct {
	channel:         string,
	status:          Stream_Status,
	chat:            ^Chat,
	chat_view:       Chat_View,
	show_chat:       bool,
	// The channel's user ID, once the chat has joined.
	room_id:         string,
	new_video_frame: bool,
	input:           Text_Input,
	card:            User_Card,
	// How far the chat box's text is scrolled to keep the cursor in view, in pixels.
	input_scroll:    f32,
	// When recent messages were sent (Assets.now_ms), for the rate limit.
	sent_at:         [dynamic]int,
	// From the last draw, in pixels.
	video_rect:      Rect,
	chat_rect:       Rect,
	messages_rect:   Rect,
	input_rect:      Rect,
}

// Starts watching `channel`. Each watch is a new session: jobs started for an
// earlier one are ignored when they finish.
watch_start :: proc(app: ^App, channel: string) {
	if app.screen == .Watch {
		watch_stop(app)
	}
	app.session += 1
	w := &app.watch
	w^ = {
		channel   = strings.clone(channel),
		status    = .Resolving,
		show_chat = true,
	}
	request_stream_url(&app.assets.jobs, w.channel, app.session)
	w.chat = new(Chat)
	if app.signed_in {
		chat_start(w.chat, w.channel, app.chat_wake_event, app.auth.login, app.auth.access_token)
	} else {
		chat_start(w.chat, w.channel, app.chat_wake_event)
	}
	set_title(app, w.channel)
	app.screen = .Watch
}

// Stops the video and chat and goes back to browsing.
watch_stop :: proc(app: ^App) {
	w := &app.watch
	player_command(&app.player, {"stop"})
	// Clears the video texture to black, so the next channel doesn't start on
	// this one's last frame.
	player_render(&app.player)
	chat_stop(w.chat)
	free(w.chat)
	user_card_close(app)
	chat_view_destroy(&w.chat_view)
	input_unfocus(app)
	input_destroy(&w.input)
	delete(w.sent_at)
	emotes_clear_channel(&app.assets.emotes)
	delete(w.room_id)
	delete(w.channel)
	w^ = {}
	app.session += 1
	set_title(app, "")
	app.screen = .Browse
}

set_title :: proc(app: ^App, channel: string) {
	title := fmt.tprintf("%s - twitch-app", channel) if channel != "" else "twitch-app"
	sdl.SetWindowTitle(app.window, strings.clone_to_cstring(title, context.temp_allocator))
}

// On the main thread, when the stream URL lookup finishes.
finish_resolve_job :: proc(app: ^App, p: ^Resolve_Job) {
	if app.screen != .Watch || p.session != app.session {
		return
	}
	switch p.err {
	case .None:
		player_load(&app.player, p.url)
		app.watch.status = .Playing
	case .Offline:
		app.watch.status = .Offline
	case .Streamlink_Failed:
		app.watch.status = .Failed
	}
}

// Takes new chat messages. Once the chat has joined, the channel's ID is known:
// loads its emotes and badges.
watch_chat_arrived :: proc(app: ^App) {
	w := &app.watch
	if app.screen != .Watch {
		return
	}
	arrived := make([dynamic]Chat_Message, context.temp_allocator)
	chat_take(w.chat, &arrived)
	chat_view_add(
		&w.chat_view,
		&app.assets,
		app.scale,
		w.chat_rect.w - 2 * CHAT_PADDING * app.scale,
		arrived[:],
		app.auth.login if app.signed_in else "",
	)

	if w.room_id != "" {
		return
	}
	room_id := chat_room_id(w.chat)
	if room_id == "" {
		return
	}
	w.room_id = strings.clone(room_id)
	for source in Emote_Source.Channel_7TV ..= Emote_Source.Channel_FFZ {
		emotes_request_set(&app.assets.jobs, source, room_id, app.session)
	}
	if app.signed_in {
		emotes_request_badges(&app.assets.jobs, app.client_id, app.auth, room_id, app.session)
	}
}

// Returns true if the key was used.
watch_key :: proc(app: ^App, key: sdl.Keycode) -> bool {
	switch key {
	case sdl.K_ESCAPE:
		if app.watch.card.open {
			user_card_close(app)
		} else {
			watch_stop(app)
		}
	case sdl.K_SPACE:
		player_command(&app.player, {"cycle", "pause"})
	case sdl.K_M:
		player_command(&app.player, {"cycle", "mute"})
	case sdl.K_UP:
		player_command(&app.player, {"add", "volume", VOLUME_STEP})
	case sdl.K_DOWN:
		player_command(&app.player, {"add", "volume", "-" + VOLUME_STEP})
	case sdl.K_C:
		app.watch.show_chat = !app.watch.show_chat
		user_card_close(app)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		input_focus(app)
	case:
		return false
	}
	return true
}

// Lays out the screen and has mpv draw its frame. Call before renderer_begin: mpv
// changes the OpenGL viewport and framebuffer while it draws.
watch_prepare :: proc(app: ^App, screen: Rect) {
	w := &app.watch
	chat_w := min(f32(i32(CHAT_WIDTH * app.scale)), screen.w / 2) if w.show_chat else 0
	w.video_rect = {0, 0, screen.w - chat_w, screen.h}
	w.chat_rect = {w.video_rect.w, 0, chat_w, screen.h}
	pad := CHAT_PADDING * app.scale
	box_h := line_height(&app.assets.renderer, .Regular, CHAT_FONT_SIZE * app.scale) + 2 * pad
	w.input_rect = {w.chat_rect.x + pad, screen.h - pad - box_h, chat_w - 2 * pad, box_h}
	w.messages_rect = {w.chat_rect.x, 0, chat_w, w.input_rect.y - pad}

	// A resize draws the frame again at the new size.
	video_size := [2]i32{i32(w.video_rect.w), i32(w.video_rect.h)}
	if video_size != app.player.target_size {
		player_resize(&app.player, video_size)
	} else if w.new_video_frame {
		player_render(&app.player)
	}
	w.new_video_frame = false
}

draw_watch :: proc(app: ^App) {
	a := &app.assets
	w := &app.watch
	video := w.video_rect
	text_size := BROWSE_CARD_TEXT_SIZE * app.scale
	switch w.status {
	case .Playing:
		draw_image(&a.renderer, app.player.texture, video)
	case .Resolving:
		draw_centered(&a.renderer, .Regular, text_size, video, fmt.tprintf("Loading %s...", w.channel), BROWSE_DIM_TEXT)
	case .Offline:
		draw_centered(&a.renderer, .Regular, text_size, video, fmt.tprintf("%s is offline. Esc to go back.", w.channel), BROWSE_DIM_TEXT)
	case .Failed:
		draw_centered(&a.renderer, .Regular, text_size, video, "Couldn't load the stream. Esc to go back.", BROWSE_DIM_TEXT)
	}
	if w.show_chat {
		draw_rect(&a.renderer, w.chat_rect, CHAT_BACKGROUND)
		draw_chat_view(a, &w.chat_view, w.messages_rect, app.scale)
		draw_input(app)
		draw_user_card(app)
	}
}

// The chat box: what's typed, or a hint, with a cursor while focused.
@(private = "file")
draw_input :: proc(app: ^App) {
	r := &app.assets.renderer
	w := &app.watch
	box := w.input_rect
	scale := app.scale
	size := CHAT_FONT_SIZE * scale
	pad := CHAT_PADDING * scale
	if w.input.focused {
		draw_rect(r, box, BROWSE_ACCENT)
		draw_rect(r, {box.x + 2 * scale, box.y + 2 * scale, box.w - 4 * scale, box.h - 4 * scale}, INPUT_BACKGROUND)
	} else {
		draw_rect(r, box, INPUT_BACKGROUND)
	}

	text := input_text(&w.input)
	inner := Rect{box.x + pad, box.y, box.w - 2 * pad, box.h}
	ty := box.y + pad
	if text == "" && !w.input.focused {
		hint := "Send a message (Enter)" if app.signed_in else "Sign in to chat"
		draw_text(r, .Regular, size, inner.x, ty, hint, CHAT_SYSTEM_TEXT)
		return
	}
	// Scroll so the cursor stays inside the box.
	cursor_x := text_width(r, .Regular, size, text[:w.input.cursor])
	if cursor_x - w.input_scroll > inner.w - 2 * scale {
		w.input_scroll = cursor_x - inner.w + 2 * scale
	} else if cursor_x < w.input_scroll {
		w.input_scroll = cursor_x
	}
	clip_begin(r, inner)
	draw_text(r, .Regular, size, inner.x - w.input_scroll, ty, text, CHAT_TEXT)
	if w.input.focused {
		draw_rect(r, {inner.x + cursor_x - w.input_scroll, ty, 2 * scale, line_height(r, .Regular, size)}, CHAT_TEXT)
	}
	clip_end(r)
}

input_focus :: proc(app: ^App) {
	w := &app.watch
	if !app.signed_in || !w.show_chat || w.input.focused {
		return
	}
	w.input.focused = true
	if !sdl.StartTextInput(app.window) {
		log.warnf("can't start text input, so typing won't work: %s", sdl.GetError())
	}
}

input_unfocus :: proc(app: ^App) {
	if app.watch.input.focused {
		app.watch.input.focused = false
		_ = sdl.StopTextInput(app.window)
	}
}

watch_click :: proc(app: ^App, x, y: f32) {
	w := &app.watch
	if w.card.open && in_rect(w.card.rect, x, y) {
		return
	}
	if w.show_chat && in_rect(w.input_rect, x, y) {
		input_focus(app)
		return
	}
	input_unfocus(app)
	if login, found := chat_view_name_at(&w.chat_view, x, y); found {
		user_card_open(app, login, y)
		return
	}
	user_card_close(app)
	chat_view_click(&w.chat_view, x, y)
}

watch_text_input :: proc(app: ^App, text: string) {
	if app.watch.input.focused {
		input_insert(&app.watch.input, text)
	}
}

// Keys while typing in the chat box.
watch_input_key :: proc(app: ^App, key: sdl.KeyboardEvent) {
	ti := &app.watch.input
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}
	by: Input_Move = .Word if ctrl else .Char
	switch key.key {
	case sdl.K_ESCAPE:
		input_unfocus(app)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		watch_send(app)
	case sdl.K_BACKSPACE:
		input_delete(ti, by)
	case sdl.K_DELETE:
		input_delete(ti, by, forward = true)
	case sdl.K_LEFT:
		input_move(ti, by, forward = false)
	case sdl.K_RIGHT:
		input_move(ti, by, forward = true)
	case sdl.K_HOME:
		input_move(ti, .Line, forward = false)
	case sdl.K_END:
		input_move(ti, .Line, forward = true)
	case sdl.K_TAB:
		emote_names, user_names := completion_names(app)
		input_complete(ti, emote_names, user_names, backwards = shift)
	case sdl.K_V:
		if ctrl {
			paste(ti)
		}
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

// Names Tab can complete: every emote loaded, and everyone who has talked in the
// chat shown. Allocated with the temp allocator.
@(private = "file")
completion_names :: proc(app: ^App) -> (emote_names, user_names: []string) {
	emotes := make([dynamic]string, context.temp_allocator)
	for &set in app.assets.emotes.sets {
		for name in set {
			append(&emotes, name)
		}
	}
	users := make([dynamic]string, context.temp_allocator)
	for m in app.watch.chat_view.messages {
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
watch_send :: proc(app: ^App) {
	w := &app.watch
	text := strings.trim_space(input_text(&w.input))
	if text == "" {
		return
	}
	line := text
	if strings.has_prefix(text, "/me ") {
		line = strings.concatenate({"\x01ACTION ", text[len("/me "):], "\x01"}, context.temp_allocator)
	} else if strings.has_prefix(text, "/") {
		notice(app, "Only /me works here so far.")
		return
	}

	now := app.assets.now_ms
	for len(w.sent_at) > 0 && now - w.sent_at[0] > CHAT_RATE_WINDOW_MS {
		ordered_remove(&w.sent_at, 0)
	}
	if len(w.sent_at) >= CHAT_RATE_LIMIT {
		notice(app, "Slow down: Twitch allows 20 messages every 30 seconds.")
		return
	}
	append(&w.sent_at, now)
	chat_send(w.chat, line)
	input_clear(&w.input)
}

// Shows a message from the app in chat.
@(private = "file")
notice :: proc(app: ^App, text: string) {
	w := &app.watch
	messages := []Chat_Message{system_message(text)}
	chat_view_add(&w.chat_view, &app.assets, app.scale, w.messages_rect.w - 2 * CHAT_PADDING * app.scale, messages)
}
