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
// With chats hidden, the tab to show them appears while the mouse is this close to
// the window's right edge.
SHOW_CHAT_ZONE :: 80
SHOW_CHAT_TAB :: [2]f32{28, 64}
VOLUME_STEP :: 5
// How long the volume bar shows after a change.
VOLUME_OSD_MS :: 1500
VOLUME_BAR_WIDTH :: 160
// The video's controls (the quality button) show this long after the mouse moves.
CONTROLS_MS :: 2000
MENU_ITEM_HEIGHT :: 34
MENU_WIDTH :: 160
MENU_HOVER :: Color{0x3a, 0x3a, 0x44, 255}
// The part of the volume bar above 100%.
VOLUME_BOOST :: Color{0xff, 0x9f, 0x43, 255}
CHAT_TOGGLE_BACKGROUND :: Color{0x18, 0x18, 0x1b, 220}

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
	// Until when (Assets.now_ms) the volume bar shows.
	volume_osd_until: int,
	// Until when the video's controls show; the quality menu is open.
	controls_until:   int,
	quality_menu:     bool,
	// From the last draw, in pixels (zero size when hidden).
	quality_button:   Rect,
	quality_items:    [Quality]Rect,
	// From the last draw, in pixels: the video, the header button that hides the
	// chats, and the tab that shows them again (zero size when not shown).
	video_rect:      Rect,
	hide_button:     Rect,
	show_tab:        Rect,
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
		s, ok = streamlink_start(w.channel, app.layout.quality, app.client_id, app.auth.access_token)
	} else {
		s, ok = streamlink_start(w.channel, app.layout.quality)
	}
	if !ok {
		w.status = .Failed
		return
	}
	w.streamlink = s
	player_load(&app.player, streamlink_url(&w.streamlink))
}

// Switches the stream to `q` (restarting it) and remembers it for every channel.
watch_set_quality :: proc(app: ^App, q: Quality) {
	w := &app.watch
	w.quality_menu = false
	if q == app.layout.quality {
		return
	}
	app.layout.quality = q
	layout_save(&app.layout)
	player_command(&app.player, {"stop"})
	streamlink_stop(&w.streamlink)
	start_stream(app, signed = app.signed_in)
}

// The mouse moved over the window: show the video's controls for a while.
watch_mouse_moved :: proc(app: ^App, x, y: f32) {
	if in_rect(app.watch.video_rect, x, y) {
		app.watch.controls_until = app.assets.now_ms + CONTROLS_MS
	}
}

// ms until the controls hide, for the main loop's wait; -1 if they aren't showing.
controls_wait :: proc(app: ^App) -> int {
	w := &app.watch
	left := w.controls_until - app.assets.now_ms
	return left if app.screen == .Watch && !w.quality_menu && left > 0 else -1
}

// Whether (x, y) is on the video's controls, which take clicks rather than
// dragging the window.
on_controls :: proc(app: ^App, x, y: f32) -> bool {
	w := &app.watch
	if w.quality_button.w > 0 && in_rect(w.quality_button, x, y) {
		return true
	}
	if w.quality_menu {
		for item in w.quality_items {
			if in_rect(item, x, y) {
				return true
			}
		}
	}
	return false
}

// A click on the controls. Returns true if it was used; any click elsewhere
// closes the menu.
@(private = "file")
controls_click :: proc(app: ^App, x, y: f32) -> bool {
	w := &app.watch
	if w.quality_menu {
		for item, q in w.quality_items {
			if in_rect(item, x, y) {
				watch_set_quality(app, q)
				return true
			}
		}
	}
	if w.quality_button.w > 0 && in_rect(w.quality_button, x, y) {
		w.quality_menu = !w.quality_menu
		return true
	}
	if w.quality_menu {
		w.quality_menu = false
		return true
	}
	return false
}

// The quality button at the video's bottom right, and its menu above it.
@(private = "file")
draw_controls :: proc(app: ^App) {
	w := &app.watch
	w.quality_button = {}
	w.quality_items = {}
	if app.assets.now_ms >= w.controls_until && !w.quality_menu {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	pad := 12 * scale
	label := strings.concatenate({QUALITY_LABELS[app.layout.quality], " ▾"}, context.temp_allocator)
	bw := text_width(r, .Bold, size, label) + 2 * pad
	bh := line_height(r, .Bold, size) + pad
	v := w.video_rect
	w.quality_button = {v.x + v.w - bw - 16 * scale, v.y + v.h - bh - 16 * scale, bw, bh}
	hovered := in_rect(w.quality_button, app.mouse.x, app.mouse.y)
	draw_rect(r, w.quality_button, MENU_HOVER if hovered || w.quality_menu else CHAT_TOGGLE_BACKGROUND)
	draw_centered(r, .Bold, size, w.quality_button, label, BROWSE_TEXT)
	if !w.quality_menu {
		return
	}

	item_h := MENU_ITEM_HEIGHT * scale
	menu_w := max(MENU_WIDTH * scale, bw)
	menu := Rect {
		w.quality_button.x + w.quality_button.w - menu_w,
		w.quality_button.y - 6 * scale - item_h * len(Quality),
		menu_w,
		item_h * len(Quality),
	}
	draw_rect(r, menu, USER_CARD_BACKGROUND)
	for q in Quality {
		item := Rect{menu.x, menu.y + f32(int(q)) * item_h, menu.w, item_h}
		w.quality_items[q] = item
		if in_rect(item, app.mouse.x, app.mouse.y) {
			draw_rect(r, item, MENU_HOVER)
		}
		current := q == app.layout.quality
		ty := item.y + (item_h - line_height(r, .Regular, size)) / 2
		if current {
			draw_text(r, .Bold, size, item.x + pad, ty, "✓", BROWSE_ACCENT)
		}
		draw_text(r, .Bold if current else .Regular, size, item.x + pad + 20 * scale, ty, QUALITY_LABELS[q], BROWSE_TEXT)
	}
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
		case w.quality_menu:
			w.quality_menu = false
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
		set_volume(app, app.layout.volume, !app.layout.muted)
	case sdl.K_UP:
		set_volume(app, app.layout.volume + VOLUME_STEP, false)
	case sdl.K_DOWN:
		set_volume(app, app.layout.volume - VOLUME_STEP, app.layout.muted)
	case sdl.K_C:
		watch_show_chat(app, !w.show_chat)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		box_focus(app, focused, .Chat)
	case:
		return false
	}
	return true
}

// Sets mpv's volume (0 to MAX_VOLUME; above 100 boosts) and mute, shows the
// volume bar, and saves both. Raising the volume unmutes, as in most players.
set_volume :: proc(app: ^App, volume: int, muted: bool) {
	l := &app.layout
	l.volume = clamp(volume, 0, MAX_VOLUME)
	l.muted = muted
	apply_volume(app)
	app.watch.volume_osd_until = app.assets.now_ms + VOLUME_OSD_MS
	layout_save(l)
}

// Tells mpv the saved volume and mute.
apply_volume :: proc(app: ^App) {
	volume := strings.clone_to_cstring(fmt.tprint(app.layout.volume), context.temp_allocator)
	player_command(&app.player, {"set", "volume", volume})
	player_command(&app.player, {"set", "mute", "yes" if app.layout.muted else "no"})
}

// The volume bar, at the video's top left: a speaker level or "Muted".
@(private = "file")
draw_volume :: proc(app: ^App) {
	w := &app.watch
	if app.assets.now_ms >= w.volume_osd_until {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	pad := 10 * scale
	lh := line_height(r, .Bold, size)
	label := "Muted" if app.layout.muted else fmt.tprintf("Volume %d%%", app.layout.volume)
	bar_w := VOLUME_BAR_WIDTH * scale
	panel := Rect{w.video_rect.x + 16 * scale, w.video_rect.y + 16 * scale, bar_w + 2 * pad, lh + 14 * scale + 2 * pad}
	draw_rect(r, panel, CHAT_TOGGLE_BACKGROUND)
	draw_text(r, .Bold, size, panel.x + pad, panel.y + pad, label, BROWSE_TEXT)
	// The bar spans 0 to MAX_VOLUME, with a tick at 100% and the boost above it in
	// orange.
	track := Rect{panel.x + pad, panel.y + pad + lh + 6 * scale, bar_w, 6 * scale}
	draw_rect(r, track, INPUT_BACKGROUND)
	full := track.w * 100 / MAX_VOLUME
	if !app.layout.muted {
		level := track.w * f32(app.layout.volume) / MAX_VOLUME
		draw_rect(r, {track.x, track.y, min(level, full), track.h}, BROWSE_ACCENT)
		if level > full {
			draw_rect(r, {track.x + full, track.y, level - full, track.h}, VOLUME_BOOST)
		}
	}
	draw_rect(r, {track.x + full - scale, track.y - 3 * scale, 2 * scale, track.h + 6 * scale}, BROWSE_TEXT)
}

// ms until the volume bar hides, for the main loop's wait; -1 if it isn't showing.
volume_osd_wait :: proc(app: ^App) -> int {
	left := app.watch.volume_osd_until - app.assets.now_ms
	return left if app.screen == .Watch && left > 0 else -1
}

watch_show_chat :: proc(app: ^App, show: bool) {
	w := &app.watch
	w.show_chat = show
	if !show {
		box_unfocus(app)
		user_card_close(app)
	}
}

// Whether the mouse is where the show-chat tab appears.
show_tab_hovered :: proc(app: ^App, screen_w: f32) -> bool {
	w := &app.watch
	return !w.show_chat && app.mouse.x >= screen_w - SHOW_CHAT_ZONE * app.scale && app.mouse.x < screen_w
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
	if controls_click(app, x, y) {
		return
	}
	if w.show_chat && w.hide_button.w > 0 && in_rect(w.hide_button, x, y) {
		watch_show_chat(app, false)
		return
	}
	if !w.show_chat && w.show_tab.w > 0 && in_rect(w.show_tab, x, y) {
		watch_show_chat(app, true)
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

// The wheel scrolls a chat, or over the video, changes the volume as in mpv.
watch_scroll :: proc(app: ^App, x, y, wheel_y: f32) {
	if p, _ := pane_at(app, x, y); p != nil {
		if in_rect(p.messages_rect, x, y) {
			chat_view_scroll(&p.view, wheel_y, app.scale)
		}
		return
	}
	if in_rect(app.watch.video_rect, x, y) && wheel_y != 0 {
		step := VOLUME_STEP if wheel_y > 0 else -VOLUME_STEP
		set_volume(app, app.layout.volume + step, false if step > 0 else app.layout.muted)
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
		if app.layout.quality == .Audio {
			draw_centered(&a.renderer, .Regular, text_size, video, fmt.tprintf("Audio only · %s", w.channel), BROWSE_DIM_TEXT)
		} else {
			draw_image(&a.renderer, app.player.texture, video)
		}
	case .Starting:
		draw_centered(&a.renderer, .Regular, text_size, video, fmt.tprintf("Loading %s...", w.channel), BROWSE_DIM_TEXT)
	case .Ended:
		draw_centered(&a.renderer, .Regular, text_size, video, "The stream has ended. Esc to go back.", BROWSE_DIM_TEXT)
	case .Offline:
		draw_centered(&a.renderer, .Regular, text_size, video, fmt.tprintf("%s is offline. Esc to go back.", w.channel), BROWSE_DIM_TEXT)
	case .Failed:
		draw_centered(&a.renderer, .Regular, text_size, video, "Couldn't load the stream. Esc to go back.", BROWSE_DIM_TEXT)
	}
	r := &a.renderer
	scale := app.scale
	draw_volume(app)
	draw_controls(app)
	w.hide_button = {}
	w.show_tab = {}
	if !w.show_chat {
		// A tab at the right edge, only while the mouse is near it.
		if show_tab_hovered(app, video.w) {
			size := SHOW_CHAT_TAB * scale
			w.show_tab = {video.w - size.x, (video.h - size.y) / 2, size.x, size.y}
			hovered := in_rect(w.show_tab, app.mouse.x, app.mouse.y)
			draw_rect(r, w.show_tab, CHAT_TOGGLE_BACKGROUND)
			draw_centered(r, .Bold, 20 * scale, w.show_tab, "«", BROWSE_TEXT if hovered else BROWSE_DIM_TEXT)
		}
		return
	}
	for p, i in w.panes {
		draw_pane(app, p, i == w.focus)
		if i > 0 {
			draw_rect(r, {p.rect.x, p.rect.y, scale, p.rect.h}, CHAT_DIVIDER)
		}
	}
	// "»" at the first header's left end hides the chats.
	h := w.panes[0].header_rect
	w.hide_button = {h.x, h.y, h.h, h.h}
	hovered := in_rect(w.hide_button, app.mouse.x, app.mouse.y)
	draw_centered(r, .Bold, 18 * scale, w.hide_button, "»", BROWSE_TEXT if hovered else BROWSE_DIM_TEXT)
	draw_user_card(app)
}
