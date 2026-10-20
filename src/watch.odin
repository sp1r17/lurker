package app

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

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
	// From the last draw, in pixels.
	video_rect:      Rect,
	chat_rect:       Rect,
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
	chat_start(w.chat, w.channel, app.chat_wake_event)
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
	chat_view_destroy(&w.chat_view)
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
	chat_view_add(&w.chat_view, &app.assets, app.scale, w.chat_rect.w - 2 * CHAT_PADDING * app.scale, arrived[:])

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
		watch_stop(app)
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
		draw_chat_view(a, &w.chat_view, w.chat_rect, app.scale)
	}
}
