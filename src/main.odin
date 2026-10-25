package app

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "vendor:curl"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

// The window's icon, for when no installed desktop entry gives it one.
ICON_DATA :: #load("../assets/install/lurker.png")

// Shortest wait between animation frames, so many emotes can't spin the CPU.
MIN_ANIMATION_WAIT_MS :: 10

USAGE :: `usage:
  %[0]s             browse the live channels you follow
  %[0]s <channel> [<channel>...]
                        watch a channel, with the other channels' chats split beside it
  %[0]s <video or clip link>
                        watch a past broadcast or clip (twitch.tv/videos/123?t=1h2m)
  %[0]s --login     sign in to Twitch`

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)
	// Also to a file, where there's no console to read it from (Windows).
	console := context.logger
	file_logger, has_file := open_log_file()
	if has_file {
		context.logger = log.create_multi_logger(console, file_logger)
	}
	defer if has_file {
		log.destroy_multi_logger(context.logger)
		log.destroy_file_logger(file_logger)
		context.logger = console
	}

	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			for _, entry in track.allocation_map {
				log.errorf("%v leaked %v bytes", entry.location, entry.size)
			}
			for entry in track.bad_free_array {
				log.errorf("%v bad free of %p", entry.location, entry.memory)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	login_mode := len(os.args) == 2 && os.args[1] == "--login"
	channels := make([dynamic]string, context.temp_allocator)
	video: Maybe(Twitch_Link)
	if !login_mode {
		for arg in os.args[1:] {
			link, ok := parse_twitch_link(arg)
			// A video or clip link has to be the only argument.
			if !ok || (link.kind != .Channel && len(os.args) > 2) {
				fmt.eprintfln(USAGE, os.args[0])
				os.exit(2)
			}
			if link.kind == .Channel {
				append(&channels, link.id)
			} else {
				video = link
			}
		}
	}
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK {
		log.error("curl init failed")
		os.exit(1)
	}
	config_file := config_path()
	config, config_err := load_config(config_file)
	if config_err != .None {
		log.errorf("can't load %s: %v", config_file, config_err)
		curl.global_cleanup()
		os.exit(1)
	}

	ok: bool
	switch {
	case login_mode:
		ok = login(config.client_id)
	case:
		ok = run(channels[:], config, video)
	}
	destroy_config(config)
	curl.global_cleanup()
	if !ok {
		os.exit(1)
	}
}

login :: proc(client_id: string) -> bool {
	auth, ok := login_with_device_code(client_id)
	if !ok {
		return false
	}
	defer destroy_auth(auth)
	if !save_auth(auth) {
		return false
	}
	fmt.printfln("Signed in as %s", auth.login)
	return true
}

Screen :: enum {
	Browse,
	Watch,
}

App :: struct {
	window:          ^sdl.Window,
	assets:          Assets,
	player:          Player,
	screen:          Screen,
	browse:          Browse,
	sign_in:         Sign_In,
	watch:           Watch,
	// Bumped whenever a watch starts or stops, so jobs for an old one are ignored.
	session:         int,
	// For Chat_Pane.id.
	next_pane_id:    int,
	layout:          Layout,
	chat_wake_event: u32,
	// From the last draw: the display scale, and the mouse in pixels.
	scale:           f32,
	mouse:           [2]f32,
	// Dragging the borderless window (see window.odin).
	wayland_drag:    Wayland_Drag,
	wayland_drag_ok: bool,
	// A press on a drag area that becomes a drag if the mouse moves far enough.
	drag_armed:      bool,
	drag_from:       [2]f32,
	// Set while drawing: the window buttons (zero size when not shown).
	window_buttons:  [Window_Control]Rect,
	client_id:       string,
	auth:            Auth,
	signed_in:       bool,
	// Whether the mouse cursor is hidden over idle video (see update_cursor).
	cursor_hidden:   bool,
	// Until when (Assets.now_ms) the text size shows after a change, and Ctrl+wheel
	// scrolling not yet a whole step.
	text_size_osd_until: int,
	text_size_wheel:     f32,
	// Whether the window has the keyboard focus: mentions arriving without it
	// count as unread.
	window_focused:      bool,
	// Whether the window is, or has been asked to go, fullscreen (see
	// toggle_fullscreen).
	fullscreen:          bool,
	// Where the user got to in each video (watched.odin).
	watched:             Watched,
	// Which followed channels have gone live (notify.odin).
	live:                Live_Notifier,
	// Whether a notification has added the notification area icon (Windows).
	notify_icon:         bool,
}

// Opens the window on the browse screen, or watching `channel` if it's not "".
run :: proc(channels: []string, config: Config, video: Maybe(Twitch_Link) = nil) -> bool {
	// Matches the installed desktop file, so the desktop finds its icon and name:
	// lurker.desktop, or in a Flatpak the one named after its ID.
	app_id := os.get_env("FLATPAK_ID", context.temp_allocator)
	sdl.SetHint(sdl.HINT_APP_ID, strings.clone_to_cstring(app_id if app_id != "" else APP_ID, context.temp_allocator))
	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL init failed: %s", sdl.GetError())
		return false
	}
	defer sdl.Quit()

	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))

	window := sdl.CreateWindow(APP_NAME, 1280 + CHAT_WIDTH, 720, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY, .BORDERLESS})
	if window == nil {
		log.errorf("can't create window: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroyWindow(window)
	if icon := img.Load_IO(sdl.IOFromConstMem(raw_data(ICON_DATA), len(ICON_DATA)), true); icon != nil {
		sdl.SetWindowIcon(window, icon)
		sdl.DestroySurface(icon)
	}

	gl_context := sdl.GL_CreateContext(window)
	if gl_context == nil {
		log.errorf("can't create OpenGL context: %s", sdl.GetError())
		return false
	}
	defer sdl.GL_DestroyContext(gl_context)
	gl.load_up_to(3, 3, sdl.gl_set_proc_address)
	sdl.GL_SetSwapInterval(1)

	app: App
	app.window = window
	// Without a border, the window moves by dragging the video and resizes from its
	// edges.
	app.wayland_drag_ok = wayland_drag_init(&app.wayland_drag, window)
	defer if app.wayland_drag_ok {
		wayland_drag_destroy(&app.wayland_drag)
	}
	if !sdl.SetWindowHitTest(window, window_hit_test, &app) {
		log.warnf("can't make the window draggable: %s", sdl.GetError())
	}
	app.client_id = config.client_id
	app.browse.hovered = -1
	app.window_focused = true
	a := &app.assets
	if !renderer_init(&a.renderer) {
		return false
	}
	defer renderer_destroy(&a.renderer)

	if player_init(&app.player) != .None {
		return false
	}
	defer player_destroy(&app.player)

	defer images_destroy(&a.images)
	defer emotes_destroy(&a.emotes)
	defer user_emotes_destroy(&a.user_emotes)
	defer emoji_table_destroy(&a.emoji)
	jobs_start(&a.jobs, sdl.RegisterEvents(1))
	defer jobs_stop(&a.jobs)
	for source in Emote_Source.Global_7TV ..= Emote_Source.Global_FFZ {
		emotes_request_set(&a.jobs, source)
	}
	emoji_request(&a.jobs)
	cache_request_prune(&a.jobs)

	app.auth, app.signed_in = load_auth()
	if !app.signed_in {
		log.info("not signed in: sign in from the browse screen (or --login) for followed channels, badges and chatting")
	}
	defer if app.signed_in {
		destroy_auth(app.auth)
	}
	user_emotes_request(&app)

	app.layout = layout_load()
	apply_volume(&app)
	a.renderer.text_scale = f32(app.layout.text_size) / 100
	defer layout_destroy(&app.layout)
	app.watched = watched_load()
	defer {
		watched_save(&app.watched)
		watched_destroy(&app.watched)
	}
	app.chat_wake_event = sdl.RegisterEvents(1)
	defer browse_destroy(&app.browse)
	defer live_notifier_destroy(&app.live)
	defer notifications_destroy(&app)
	defer sign_in_destroy(&app.sign_in)
	defer if app.screen == .Watch {
		watch_stop(&app)
	}
	if len(channels) > 0 {
		// Splits named on the command line replace the saved ones.
		watch_start(&app, channels[0], restore = len(channels) == 1)
		for split in channels[1:] {
			watch_add_split(&app, split)
		}
		if len(channels) > 1 {
			layout_remember(&app)
		}
	}
	if link, has_link := video.?; has_link {
		open_link(&app, link)
	}

	draw(&app)
	for running := true; running; {
		defer free_all(context.temp_allocator)

		// Wake up for the next animation frame, browse refresh or sign-in poll,
		// whichever is due first.
		wait := a.next_frame_ms if a.next_frame_ms >= 0 else -1
		dues := []int{-1, -1, volume_osd_wait(&app), controls_wait(&app), stream_info_tick(&app), stream_end_tick(&app), text_size_osd_wait(&app), replay_tick(&app), watched_tick(&app), resume_notice_wait(&app), live_poll_tick(&app)}
		if app.screen == .Browse {
			dues[0], dues[1] = browse_tick(&app), sign_in_tick(&app)
		}
		for due in dues {
			if due >= 0 && (wait < 0 || due < wait) {
				wait = due
			}
		}
		e: sdl.Event
		redraw := false
		if wait >= 0 {
			if !sdl.WaitEventTimeout(&e, i32(max(wait, MIN_ANIMATION_WAIT_MS))) {
				draw(&app)
				continue
			}
		} else if !sdl.WaitEvent(&e) {
			log.errorf("waiting for events failed: %s", sdl.GetError())
			return false
		}

		wayland_drag_update(&app.wayland_drag)
		// Handle everything that's queued before drawing once.
		for {
			if !handle_event(&app, e, &redraw) {
				running = false
			}
			if !sdl.PollEvent(&e) {
				break
			}
		}
		if redraw && running {
			draw(&app)
		}
	}
	return true
}

// Ctrl+= (or Ctrl++) and Ctrl+- make the text bigger and smaller, Ctrl+0 back
// to normal, on any screen and while typing. Returns true if the key was used.
text_size_key :: proc(app: ^App, key: sdl.KeyboardEvent) -> bool {
	if key.mod & sdl.KMOD_CTRL == {} {
		return false
	}
	size := app.layout.text_size
	switch key.key {
	case sdl.K_EQUALS, sdl.K_PLUS, sdl.K_KP_PLUS:
		size += TEXT_SIZE_STEP
	case sdl.K_MINUS, sdl.K_KP_MINUS:
		size -= TEXT_SIZE_STEP
	case sdl.K_0, sdl.K_KP_0:
		size = DEFAULT_TEXT_SIZE
	case:
		return false
	}
	set_text_size(app, size)
	return true
}

// Sets the text size (a percentage, clamped to MIN_TEXT_SIZE..MAX_TEXT_SIZE) and
// saves it.
set_text_size :: proc(app: ^App, size: int) {
	l := &app.layout
	clamped := clamp(size, MIN_TEXT_SIZE, MAX_TEXT_SIZE)
	// Shown even at a limit, which says why nothing changed.
	app.text_size_osd_until = app.assets.now_ms + TEXT_SIZE_OSD_MS
	if clamped == l.text_size {
		return
	}
	l.text_size = clamped
	app.assets.renderer.text_scale = f32(clamped) / 100
	layout_save(l)
}

// Returns false to quit.
handle_event :: proc(app: ^App, e: sdl.Event, redraw: ^bool) -> bool {
	density := sdl.GetWindowPixelDensity(app.window)
	switch {
	case e.type == .QUIT:
		return false
	case e.type == .WINDOW_EXPOSED || e.type == .WINDOW_PIXEL_SIZE_CHANGED:
		redraw^ = true
	case e.type == .TEXT_INPUT:
		if app.screen == .Watch {
			pane_text_input(app, string(e.text.text))
			redraw^ = true
		} else if app.browse.search.focused {
			browse_search_text(app, string(e.text.text))
			redraw^ = true
		}
	case e.type == .KEY_DOWN && text_size_key(app, e.key):
		redraw^ = true
	case e.type == .KEY_DOWN && app.screen == .Watch && is_typing(app):
		// Typing: every key goes to the box.
		pane_input_key(app, e.key)
		redraw^ = true
	case e.type == .KEY_DOWN && app.screen == .Browse && app.browse.search.focused:
		browse_search_key(app, e.key)
		redraw^ = true
	case e.type == .KEY_DOWN:
		switch e.key.key {
		case sdl.K_Q:
			return false
		case sdl.K_F:
			if e.key.mod & sdl.KMOD_CTRL != {} {
				// Ctrl+F searches the focused chat, or channels when browsing.
				if app.screen == .Watch {
					search_open(app, app.watch.panes[app.watch.focus])
				} else {
					browse_search_focus(app)
				}
				redraw^ = true
				break
			}
			toggle_fullscreen(app)
		case:
			switch app.screen {
			case .Watch:
				if !watch_key(app, e.key) {
					return true
				}
			case .Browse:
				switch e.key.key {
				case sdl.K_ESCAPE:
					switch {
					case sign_in_active(app):
						sign_in_cancel(app)
					case browse_back(app):
					case:
						return false
					}
				case sdl.K_SLASH, sdl.K_KP_DIVIDE:
					// The "/" itself may also arrive as text; it isn't typed.
					browse_search_focus(app)
					app.browse.skip_slash = true
				case sdl.K_R:
					browse_refresh(app)
					if app.browse.view == .Following {
						offline_refresh(app, force = true)
					}
				case sdl.K_L:
					if !app.signed_in {
						sign_in_start(app)
					}
				}
			}
			redraw^ = true
		}
	case e.type == .WINDOW_ENTER_FULLSCREEN || e.type == .WINDOW_LEAVE_FULLSCREEN:
		// Also from the compositor (a keyboard shortcut, say), not only from us.
		app.fullscreen = e.type == .WINDOW_ENTER_FULLSCREEN
		redraw^ = true
	case e.type == .WINDOW_MAXIMIZED || e.type == .WINDOW_RESTORED:
		// The maximize button's icon follows.
		redraw^ = true
	case e.type == .WINDOW_FOCUS_GAINED || e.type == .WINDOW_FOCUS_LOST:
		app.window_focused = e.type == .WINDOW_FOCUS_GAINED
		redraw^ = true
	case e.type == .WINDOW_MOUSE_LEAVE:
		// Hover states and the video's controls go with the mouse.
		app.mouse = {-1, -1}
		app.watch.controls_until = 0
		redraw^ = true
	case e.type == .MOUSE_MOTION:
		app.mouse = {e.motion.x * density, e.motion.y * density}
		if .LEFT in e.motion.state {
			window_drag_motion(app, app.mouse.x, app.mouse.y)
		} else {
			app.drag_armed = false
		}
		if app.screen == .Watch {
			watch_mouse_moved(app, app.mouse.x, app.mouse.y)
		}
		if app.screen == .Browse {
			app.browse.hovered = browse_card_at(&app.browse, app.mouse.x, app.mouse.y)
			// Cards, tabs, buttons and links change colour under the mouse.
			redraw^ = true
		}
		if app.screen == .Watch {
			// The hide button lights up, and the show-chat tab appears, under the
			// mouse. Video frames redraw anyway; a paused or ended stream doesn't.
			redraw^ = true
		}
	case e.type == .MOUSE_WHEEL:
		x, y := e.wheel.mouse_x * density, e.wheel.mouse_y * density
		if sdl.GetModState() & sdl.KMOD_CTRL != {} {
			// Ctrl+wheel sizes the text, a step per notch (touchpads scroll in
			// fractions, which add up).
			app.text_size_wheel += e.wheel.y
			steps := int(app.text_size_wheel)
			if steps != 0 {
				app.text_size_wheel -= f32(steps)
				set_text_size(app, app.layout.text_size + steps * TEXT_SIZE_STEP)
			}
			redraw^ = true
			break
		}
		switch app.screen {
		case .Watch:
			watch_scroll(app, x, y, e.wheel.y)
			redraw^ = true
		case .Browse:
			browse_scroll(&app.browse, e.wheel.y, app.scale)
			app.browse.hovered = browse_card_at(&app.browse, x, y)
			redraw^ = true
		}
	case e.type == .MOUSE_BUTTON_UP:
		app.drag_armed = false
	case e.type == .MOUSE_BUTTON_DOWN:
		// The mouse's back button leaves the stream, like a browser's.
		if e.button.button == sdl.BUTTON_X1 && app.screen == .Watch {
			watch_stop(app)
			redraw^ = true
			return true
		}
		// A right-click on a chat message replies to it.
		if e.button.button == sdl.BUTTON_RIGHT && app.screen == .Watch {
			watch_right_click(app, e.button.x * density, e.button.y * density)
			redraw^ = true
			return true
		}
		if e.button.button != sdl.BUTTON_LEFT {
			return true
		}
		x, y := e.button.x * density, e.button.y * density
		redraw^ = true
		if window_controls_click(app, x, y) {
			return true
		}
		window_press(app, x, y, e.button.clicks)
		switch app.screen {
		case .Watch:
			watch_click(app, x, y)
			redraw^ = true
		case .Browse:
			browse_click(app, x, y)
		}
	case u32(e.type) == app.chat_wake_event:
		watch_chat_arrived(app)
		redraw^ = true
	case u32(e.type) == app.assets.jobs.wake_event:
		finish_jobs(app)
		redraw^ = true
	case u32(e.type) == app.player.events_event:
		events := player_handle_events(&app.player)
		if .Shutdown in events {
			return false
		}
		watch_player_events(app, events)
		redraw^ = true
	case u32(e.type) == app.player.redraw_event:
		if player_wants_redraw(&app.player) && app.screen == .Watch {
			app.watch.new_video_frame = true
			redraw^ = true
		}
	}
	return true
}

finish_jobs :: proc(app: ^App) {
	a := &app.assets
	done := make([dynamic]^Job, context.temp_allocator)
	jobs_take(&a.jobs, &done)
	for job in done {
		switch &p in job.payload {
		case Image_Job:
			finish_image_job(&a.images, &p)
		case Emote_Set_Job:
			if p.source >= .Global_7TV {
				finish_emote_set_job(&a.emotes, &p)
			} else if pane := find_pane(app, p.pane); pane != nil {
				// A channel's set arriving after its pane closed is dropped.
				finish_emote_set_job(&pane.emotes, &p)
			}
		case Badges_Job:
			pane := find_pane(app, p.pane)
			finish_badges_job(&pane.emotes if pane != nil else nil, &a.emotes, &p)
			apply_auth_check(app, p.check, p.auth)
		case Streams_Job:
			apply_auth_check(app, p.check, p.auth)
			finish_streams_job(app, &p)
		case Categories_Job:
			apply_auth_check(app, p.check, p.auth)
			finish_categories_job(app, &p)
		case Search_Job:
			apply_auth_check(app, p.check, p.auth)
			finish_search_job(app, &p)
		case Device_Start_Job:
			finish_device_start_job(app, &p)
		case Device_Poll_Job:
			finish_device_poll_job(app, &p)
		case User_Job:
			finish_user_job(app, &p)
		case Stream_Info_Job:
			finish_stream_info_job(app, &p)
		case Follow_Job:
			finish_follow_job(app, &p)
		case Offline_Follows_Job:
			finish_offline_follows_job(app, &p)
		case Vod_Job:
			finish_vod_job(app, &p)
		case Vod_Url_Job:
			finish_vod_url_job(app, &p)
		case Vod_Chat_Job:
			finish_vod_chat_job(app, &p)
		case Videos_Job:
			finish_videos_job(app, &p)
		case Link_Job:
			finish_link_job(app, &p)
		case Vod_Extras_Job:
			finish_vod_extras_job(app, &p)
		case User_Emotes_Job:
			finish_user_emotes_job(app, &p)
		case Emoji_Job:
			finish_emoji_job(a, &p)
		case Cache_Prune_Job:
		case Notify_Job:
		}
		destroy_job(job)
	}
}

// Saves a sign-in a job refreshed, or forgets one Twitch rejected.
apply_auth_check :: proc(app: ^App, check: Auth_Check, job_auth: Auth) {
	if !app.signed_in {
		return
	}
	switch check {
	case .Valid, .Unreachable:
	case .Refreshed:
		destroy_auth(app.auth)
		app.auth = clone_auth(job_auth)
		save_auth(app.auth)
	case .Signed_Out:
		destroy_auth(app.auth)
		app.auth = {}
		app.signed_in = false
	}
}

is_typing :: proc(app: ^App) -> bool {
	_, _, typing := focused_box(app)
	return typing
}

in_rect :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

draw :: proc(app: ^App) {
	a := &app.assets
	w, h: i32
	sdl.GetWindowSizeInPixels(app.window, &w, &h)
	app.scale = sdl.GetWindowDisplayScale(app.window)
	a.now_ms = int(sdl.GetTicks())
	screen := Rect{0, 0, f32(w), f32(h)}

	if app.screen == .Watch {
		watch_prepare(app, screen)
	}
	// The font atlas can grow mid-frame, which needs one more pass.
	for _ in 0 ..< 2 {
		a.next_frame_ms = -1
		app.window_buttons = {}
		renderer_begin(&a.renderer, w, h)
		gl.ClearColor(0, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		switch app.screen {
		case .Browse:
			draw_browse(app, screen)
		case .Watch:
			draw_watch(app)
		}
		draw_text_size_osd(app, screen)
		if renderer_end(&a.renderer) {
			break
		}
	}
	sdl.GL_SwapWindow(app.window)
	player_report_swap(&app.player)
	update_cursor(app)
}

// The text size, in the middle of the window's top, for a moment after it
// changes, with a bar from MIN_TEXT_SIZE to MAX_TEXT_SIZE.
draw_text_size_osd :: proc(app: ^App, screen: Rect) {
	if app.assets.now_ms >= app.text_size_osd_until {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	pad := 10 * scale
	lh := line_height(r, .Bold, size)
	label := fmt.tprintf("Text size %d%%", app.layout.text_size)
	bar_w := max(VOLUME_BAR_WIDTH * scale, text_width(r, .Bold, size, label))
	panel := Rect{screen.x + (screen.w - bar_w) / 2 - pad, screen.y + 72 * scale, bar_w + 2 * pad, lh + 14 * scale + 2 * pad}
	draw_rect(r, panel, CHAT_TOGGLE_BACKGROUND)
	draw_text(r, .Bold, size, panel.x + (panel.w - text_width(r, .Bold, size, label)) / 2, panel.y + pad, label, BROWSE_TEXT)
	track := Rect{panel.x + pad, panel.y + pad + lh + 6 * scale, bar_w, 6 * scale}
	draw_rect(r, track, INPUT_BACKGROUND)
	level := track.w * f32(app.layout.text_size - MIN_TEXT_SIZE) / f32(MAX_TEXT_SIZE - MIN_TEXT_SIZE)
	draw_rect(r, {track.x, track.y, level, track.h}, BROWSE_ACCENT)
	// A tick at the normal size.
	normal := track.w * f32(DEFAULT_TEXT_SIZE - MIN_TEXT_SIZE) / f32(MAX_TEXT_SIZE - MIN_TEXT_SIZE)
	draw_rect(r, {track.x + normal - scale, track.y - 3 * scale, 2 * scale, track.h + 6 * scale}, BROWSE_TEXT)
}

// ms until the text size indicator hides, for the main loop's wait; -1 if it isn't showing.
text_size_osd_wait :: proc(app: ^App) -> int {
	left := app.text_size_osd_until - app.assets.now_ms
	return left if left > 0 else -1
}

// Hides the mouse cursor over the video once it's been still long enough for the
// controls to hide, as video players do; moving it brings both back.
update_cursor :: proc(app: ^App) {
	hide :=
		app.screen == .Watch &&
		!controls_visible(app) &&
		in_rect(app.watch.video_rect, app.mouse.x, app.mouse.y)
	if hide == app.cursor_hidden {
		return
	}
	app.cursor_hidden = hide
	if hide {
		_ = sdl.HideCursor()
	} else {
		_ = sdl.ShowCursor()
	}
}
