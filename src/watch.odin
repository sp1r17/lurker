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
SELECTION_BACKGROUND :: Color{0x91, 0x47, 0xff, 110}
// The chats never take more of the window than this; with many splits, each gets
// narrower.
MAX_CHAT_SHARE :: 0.6

Stream_Status :: enum {
	// Streamlink is starting, or waiting out pre-roll ads.
	Starting,
	Playing,
	Offline,
	Ended,
	Failed,
}

// Watching one channel: its video, its chat, and any other chats split beside it.
Watch :: struct {
	channel:         string,
	status:          Stream_Status,
	streamlink:      Streamlink,
	// Streamlink was given the sign-in (for Turbo); cleared if that failed and
	// it's running anonymously instead.
	signed_stream:   bool,
	new_video_frame: bool,
	show_chat:       bool,
	// panes[0] is the watched channel's chat; the rest are splits (Ctrl+T).
	panes:           [dynamic]^Chat_Pane,
	// The pane keys like Enter and Ctrl+F act on.
	focus:           int,
	card:            User_Card,
	// When recent messages were sent (Assets.now_ms), for the rate limit.
	sent_at:         [dynamic]int,
	// From the last draw, in pixels.
	video_rect:      Rect,
}

// Starts watching `channel`, with the splits last open with it unless not
// `restore`. Each watch is a new session: jobs started for an earlier one are
// ignored when they finish.
watch_start :: proc(app: ^App, channel: string, restore := true) {
	if app.screen == .Watch {
		watch_stop(app)
	}
	app.session += 1
	w := &app.watch
	w^ = {
		channel   = strings.clone(channel),
		status    = .Starting,
		show_chat = true,
	}
	start_stream(app, signed = app.signed_in)
	p := pane_new(app)
	pane_join(app, p, w.channel)
	append(&w.panes, p)
	if restore {
		for split in layout_splits(app, w.channel) {
			watch_add_split(app, split)
		}
	}
	set_title(app, w.channel)
	app.screen = .Watch
}

// Opens `channel`'s chat as a split.
watch_add_split :: proc(app: ^App, channel: string) {
	p := pane_new(app)
	pane_join(app, p, channel)
	append(&app.watch.panes, p)
}

// Stops the video and chats and goes back to browsing.
watch_stop :: proc(app: ^App) {
	w := &app.watch
	player_command(&app.player, {"stop"})
	streamlink_stop(&w.streamlink)
	// Clears the video texture to black, so the next channel doesn't start on
	// this one's last frame.
	player_render(&app.player)
	user_card_close(app)
	box_unfocus(app)
	for p in w.panes {
		pane_destroy(app, p)
	}
	delete(w.panes)
	delete(w.sent_at)
	delete(w.channel)
	w^ = {}
	app.session += 1
	set_title(app, "")
	app.screen = .Browse
}

// Adds a split that asks which channel to join.
watch_add_pane :: proc(app: ^App) {
	w := &app.watch
	w.show_chat = true
	p := pane_new(app)
	append(&w.panes, p)
	w.focus = len(w.panes) - 1
	box_focus(app, p, .Chat)
}

// Closes a split. The watched channel's own chat (panes[0]) stays.
watch_close_pane :: proc(app: ^App, p: ^Chat_Pane) {
	w := &app.watch
	for pane, i in w.panes {
		if pane != p || i == 0 {
			continue
		}
		if w.card.open && w.card.pane == p.id {
			user_card_close(app)
		}
		had_channel := p.channel != ""
		pane_destroy(app, p)
		ordered_remove(&w.panes, i)
		w.focus = min(w.focus, len(w.panes) - 1)
		if had_channel {
			layout_remember(app)
		}
		return
	}
}

// The pane with this ID, or nil if it has closed.
find_pane :: proc(app: ^App, id: int) -> ^Chat_Pane {
	for p in app.watch.panes {
		if p.id == id {
			return p
		}
	}
	return nil
}

set_title :: proc(app: ^App, channel: string) {
	title := fmt.tprintf("%s - twitch-app", channel) if channel != "" else "twitch-app"
	sdl.SetWindowTitle(app.window, strings.clone_to_cstring(title, context.temp_allocator))
}

@(private = "file")
start_stream :: proc(app: ^App, signed: bool) {
	w := &app.watch
	w.status = .Starting
	w.signed_stream = signed
	s: Streamlink
	ok: bool
	if signed {
		s, ok = streamlink_start(w.channel, app.client_id, app.auth.access_token)
	} else {
		s, ok = streamlink_start(w.channel)
	}
	if !ok {
		w.status = .Failed
		return
	}
	w.streamlink = s
	player_load(&app.player, streamlink_url(&w.streamlink))
}

// Acts on what mpv reports: the stream showing, or ending.
watch_player_events :: proc(app: ^App, events: Player_Events) {
	w := &app.watch
	if app.screen != .Watch {
		return
	}
	if .File_Loaded in events {
		w.status = .Playing
	}
	if .Ended in events {
		switch streamlink_outcome(&w.streamlink) {
		case .None, .Ended:
			w.status = .Ended
		case .Offline:
			w.status = .Offline
		case .Streamlink_Failed:
			if w.signed_stream && w.status == .Starting {
				// Twitch may refuse the sign-in for playback; watching without it beats
				// not watching (streamlink still cuts the ads).
				log.warn("streamlink failed with the sign-in; trying without it")
				start_stream(app, signed = false)
				return
			}
			w.status = .Failed
		}
	}
}

// Takes new messages from every chat.
watch_chat_arrived :: proc(app: ^App) {
	if app.screen != .Watch {
		return
	}
	for p in app.watch.panes {
		pane_chat_arrived(app, p)
	}
}

// Keys when not typing. Returns true if the key was used.
watch_key :: proc(app: ^App, key: sdl.KeyboardEvent) -> bool {
	w := &app.watch
	focused := w.panes[w.focus]
	if key.mod & sdl.KMOD_CTRL != {} {
		switch key.key {
		case sdl.K_T:
			watch_add_pane(app)
		case sdl.K_W:
			watch_close_pane(app, focused)
		case:
			return false
		}
		return true
	}
	switch key.key {
	case sdl.K_ESCAPE:
		switch {
		case w.card.open:
			user_card_close(app)
		case focused.searching:
			search_close(app, focused)
		case:
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
		w.show_chat = !w.show_chat
		user_card_close(app)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		box_focus(app, focused, .Chat)
	case:
		return false
	}
	return true
}

// The pane under (x, y), or nil.
pane_at :: proc(app: ^App, x, y: f32) -> (p: ^Chat_Pane, index: int) {
	if !app.watch.show_chat {
		return nil, -1
	}
	for pane, i in app.watch.panes {
		if in_rect(pane.rect, x, y) {
			return pane, i
		}
	}
	return nil, -1
}

watch_click :: proc(app: ^App, x, y: f32) {
	w := &app.watch
	if w.card.open && in_rect(w.card.rect, x, y) {
		return
	}
	p, i := pane_at(app, x, y)
	if p == nil {
		box_unfocus(app)
		user_card_close(app)
		return
	}
	w.focus = i
	pane_click(app, p, x, y)
}

watch_scroll :: proc(app: ^App, x, y, wheel_y: f32) {
	if p, _ := pane_at(app, x, y); p != nil && in_rect(p.messages_rect, x, y) {
		chat_view_scroll(&p.view, wheel_y, app.scale)
	}
}

// Lays out the screen and has mpv draw its frame. Call before renderer_begin: mpv
// changes the OpenGL viewport and framebuffer while it draws.
watch_prepare :: proc(app: ^App, screen: Rect) {
	w := &app.watch
	n := f32(len(w.panes)) if w.show_chat else 0
	pane_w := min(f32(i32(CHAT_WIDTH * app.scale)), screen.w * MAX_CHAT_SHARE / max(n, 1))
	chats_w := pane_w * n
	w.video_rect = {0, 0, screen.w - chats_w, screen.h}
	for p, i in w.panes {
		pane_layout(app, p, {w.video_rect.w + f32(i) * pane_w, 0, pane_w, screen.h})
	}

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
	case .Starting:
		draw_centered(&a.renderer, .Regular, text_size, video, fmt.tprintf("Loading %s...", w.channel), BROWSE_DIM_TEXT)
	case .Ended:
		draw_centered(&a.renderer, .Regular, text_size, video, "The stream has ended. Esc to go back.", BROWSE_DIM_TEXT)
	case .Offline:
		draw_centered(&a.renderer, .Regular, text_size, video, fmt.tprintf("%s is offline. Esc to go back.", w.channel), BROWSE_DIM_TEXT)
	case .Failed:
		draw_centered(&a.renderer, .Regular, text_size, video, "Couldn't load the stream. Esc to go back.", BROWSE_DIM_TEXT)
	}
	if !w.show_chat {
		return
	}
	for p, i in w.panes {
		draw_pane(app, p, i == w.focus)
		if i > 0 {
			draw_rect(&a.renderer, {p.rect.x, p.rect.y, app.scale, p.rect.h}, CHAT_DIVIDER)
		}
	}
	draw_user_card(app)
}
