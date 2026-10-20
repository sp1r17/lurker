package app

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "vendor:curl"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

// Shortest wait between animation frames, so many emotes can't spin the CPU.
MIN_ANIMATION_WAIT_MS :: 10

USAGE :: `usage:
  %[0]s             browse the live channels you follow
  %[0]s <channel> [<channel>...]
                        watch a channel, with the other channels' chats split beside it
  %[0]s --login     sign in to Twitch`

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

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
	if !login_mode {
		for arg in os.args[1:] {
			if !valid_login(arg) {
				fmt.eprintfln(USAGE, os.args[0])
				os.exit(2)
			}
			append(&channels, strings.to_lower(arg, context.temp_allocator))
		}
	}
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK {
		log.error("curl init failed")
		os.exit(1)
	}
	config, config_err := load_config(CONFIG_PATH)
	if config_err != .None {
		log.errorf("can't load %s: %v", CONFIG_PATH, config_err)
		curl.global_cleanup()
		os.exit(1)
	}

	ok: bool
	switch {
	case login_mode:
		ok = login(config.client_id)
	case:
		ok = run(channels[:], config)
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
	client_id:       string,
	auth:            Auth,
	signed_in:       bool,
}

// Opens the window on the browse screen, or watching `channel` if it's not "".
run :: proc(channels: []string, config: Config) -> bool {
	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL init failed: %s", sdl.GetError())
		return false
	}
	defer sdl.Quit()

	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))

	window := sdl.CreateWindow("twitch-app", 1280 + CHAT_WIDTH, 720, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY, .BORDERLESS})
	if window == nil {
		log.errorf("can't create window: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroyWindow(window)

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
	jobs_start(&a.jobs, sdl.RegisterEvents(1))
	defer jobs_stop(&a.jobs)
	for source in Emote_Source.Global_7TV ..= Emote_Source.Global_FFZ {
		emotes_request_set(&a.jobs, source)
	}

	app.auth, app.signed_in = load_auth()
	if !app.signed_in {
		log.info("not signed in: sign in from the browse screen (or --login) for followed channels, badges and chatting")
	}
	defer if app.signed_in {
		destroy_auth(app.auth)
	}

	app.layout = layout_load()
	apply_volume(&app)
	defer layout_destroy(&app.layout)
	app.chat_wake_event = sdl.RegisterEvents(1)
	defer browse_destroy(&app.browse)
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

	draw(&app)
	for running := true; running; {
		defer free_all(context.temp_allocator)

		// Wake up for the next animation frame, browse refresh or sign-in poll,
		// whichever is due first.
		wait := a.next_frame_ms if a.next_frame_ms >= 0 else -1
		dues := []int{-1, -1, volume_osd_wait(&app), controls_wait(&app)}
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
		}
	case e.type == .KEY_DOWN && app.screen == .Watch && is_typing(app):
		// Typing: every key goes to the box.
		pane_input_key(app, e.key)
		redraw^ = true
	case e.type == .KEY_DOWN:
		switch e.key.key {
		case sdl.K_Q:
			return false
		case sdl.K_F:
			if e.key.mod & sdl.KMOD_CTRL != {} {
				// Ctrl+F searches the focused chat.
				if app.screen == .Watch {
					search_open(app, app.watch.panes[app.watch.focus])
					redraw^ = true
				}
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
					if !sign_in_active(app) {
						return false
					}
					sign_in_cancel(app)
				case sdl.K_R:
					browse_refresh(app)
				case sdl.K_L:
					if !app.signed_in {
						sign_in_start(app)
					}
				}
			}
			redraw^ = true
		}
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
			hovered := browse_card_at(&app.browse, app.mouse.x, app.mouse.y)
			if hovered != app.browse.hovered {
				app.browse.hovered = hovered
				redraw^ = true
			}
			// Buttons and links change colour under the mouse.
			if !app.signed_in || app.sign_in.sign_out.w > 0 {
				redraw^ = true
			}
		}
		if app.screen == .Watch {
			// The hide button lights up, and the show-chat tab appears, under the
			// mouse. Video frames redraw anyway; a paused or ended stream doesn't.
			redraw^ = true
		}
	case e.type == .MOUSE_WHEEL:
		x, y := e.wheel.mouse_x * density, e.wheel.mouse_y * density
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
		if e.button.button != sdl.BUTTON_LEFT {
			return true
		}
		x, y := e.button.x * density, e.button.y * density
		window_press(app, x, y, e.button.clicks)
		redraw^ = true
		switch app.screen {
		case .Watch:
			watch_click(app, x, y)
			redraw^ = true
		case .Browse:
			if sign_in_click(app, x, y) {
				redraw^ = true
			} else if i := browse_card_at(&app.browse, x, y); i >= 0 {
				watch_start(app, app.browse.streams[i].user_login)
				redraw^ = true
			}
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
		case Followed_Job:
			apply_auth_check(app, p.check, p.auth)
			finish_followed_job(app, &p)
		case Device_Start_Job:
			finish_device_start_job(app, &p)
		case Device_Poll_Job:
			finish_device_poll_job(app, &p)
		case User_Job:
			finish_user_job(app, &p)
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
		renderer_begin(&a.renderer, w, h)
		gl.ClearColor(0, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		switch app.screen {
		case .Browse:
			draw_browse(app, screen)
		case .Watch:
			draw_watch(app)
		}
		if renderer_end(&a.renderer) {
			break
		}
	}
	sdl.GL_SwapWindow(app.window)
	player_report_swap(&app.player)
}
