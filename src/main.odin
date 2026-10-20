package app

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "vendor:curl"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

VOLUME_STEP :: "5"
// Shortest wait between animation frames, so many emotes can't spin the CPU.
MIN_ANIMATION_WAIT_MS :: 10

USAGE :: `usage:
  %[0]s <channel>   watch a channel
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

	if len(os.args) != 2 || (os.args[1] != "--login" && !valid_login(os.args[1])) {
		fmt.eprintfln(USAGE, os.args[0])
		os.exit(2)
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
	if os.args[1] == "--login" {
		ok = login(config.client_id)
	} else {
		// Not temp-allocated: the chat thread uses it for the whole run.
		channel := strings.to_lower(os.args[1])
		ok = run(channel, config)
		delete(channel)
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

App :: struct {
	window:          ^sdl.Window,
	assets:          Assets,
	player:          Player,
	chat_view:       Chat_View,
	show_chat:       bool,
	new_video_frame: bool,
	// From the last draw, in pixels.
	scale:           f32,
	chat_rect:       Rect,
	client_id:       string,
	auth:            Auth,
	signed_in:       bool,
	// The channel's user ID, once the chat has joined.
	room_id:         string,
}

run :: proc(channel: string, config: Config) -> bool {
	log.infof("finding %s's stream...", channel)
	url, stream_err := resolve_stream_url(channel)
	switch stream_err {
	case .None:
	case .Offline:
		log.errorf("%s is offline", channel)
		return false
	case .Streamlink_Failed:
		return false
	}
	defer delete(url)

	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL init failed: %s", sdl.GetError())
		return false
	}
	defer sdl.Quit()

	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))

	title := strings.clone_to_cstring(fmt.tprintf("%s - twitch-app", channel), context.temp_allocator)
	window := sdl.CreateWindow(title, 1280 + CHAT_WIDTH, 720, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
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
	app.client_id = config.client_id
	a := &app.assets
	if !renderer_init(&a.renderer) {
		return false
	}
	defer renderer_destroy(&a.renderer)

	if player_init(&app.player) != .None {
		return false
	}
	defer player_destroy(&app.player)
	player_load(&app.player, url)

	defer images_destroy(&a.images)
	defer emotes_destroy(&a.emotes)
	jobs_start(&a.jobs, sdl.RegisterEvents(1))
	defer jobs_stop(&a.jobs)
	for source in Emote_Source.Global_7TV ..= Emote_Source.Global_FFZ {
		emotes_request_set(&a.jobs, source)
	}

	app.auth, app.signed_in = load_auth()
	if !app.signed_in {
		log.info("not signed in: badges are hidden (sign in with --login)")
	}
	defer if app.signed_in {
		destroy_auth(app.auth)
	}
	defer delete(app.room_id)

	defer chat_view_destroy(&app.chat_view)
	chat: Chat
	chat_start(&chat, channel, sdl.RegisterEvents(1))
	defer chat_stop(&chat)
	app.show_chat = true

	fullscreen := false
	draw(&app)
	for running := true; running; {
		defer free_all(context.temp_allocator)

		e: sdl.Event
		// While an animated emote is on screen, wake up for its next frame.
		redraw := false
		if a.next_frame_ms >= 0 {
			if !sdl.WaitEventTimeout(&e, i32(max(a.next_frame_ms, MIN_ANIMATION_WAIT_MS))) {
				draw(&app)
				continue
			}
		} else if !sdl.WaitEvent(&e) {
			log.errorf("waiting for events failed: %s", sdl.GetError())
			return false
		}
		// Handle everything that's queued before drawing once.
		for {
			density := sdl.GetWindowPixelDensity(window)
			switch {
			case e.type == .QUIT:
				running = false
			case e.type == .WINDOW_EXPOSED || e.type == .WINDOW_PIXEL_SIZE_CHANGED:
				redraw = true
			case e.type == .KEY_DOWN:
				switch e.key.key {
				case sdl.K_ESCAPE, sdl.K_Q:
					running = false
				case sdl.K_SPACE:
					player_command(&app.player, {"cycle", "pause"})
				case sdl.K_M:
					player_command(&app.player, {"cycle", "mute"})
				case sdl.K_UP:
					player_command(&app.player, {"add", "volume", VOLUME_STEP})
				case sdl.K_DOWN:
					player_command(&app.player, {"add", "volume", "-" + VOLUME_STEP})
				case sdl.K_F:
					fullscreen = !fullscreen
					sdl.SetWindowFullscreen(window, fullscreen)
				case sdl.K_C:
					app.show_chat = !app.show_chat
					redraw = true
				}
			case e.type == .MOUSE_WHEEL:
				if in_rect(app.chat_rect, e.wheel.mouse_x * density, e.wheel.mouse_y * density) {
					chat_view_scroll(&app.chat_view, e.wheel.y, app.scale)
					redraw = true
				}
			case e.type == .MOUSE_BUTTON_DOWN:
				if e.button.button == sdl.BUTTON_LEFT &&
				   chat_view_click(&app.chat_view, e.button.x * density, e.button.y * density) {
					redraw = true
				}
			case u32(e.type) == chat.wake_event:
				arrived := make([dynamic]Chat_Message, context.temp_allocator)
				chat_take(&chat, &arrived)
				chat_view_add(&app.chat_view, a, app.scale, chat_content_width(app), arrived[:])
				if app.room_id == "" {
					joined(&app, chat_room_id(&chat))
				}
				redraw = true
			case u32(e.type) == a.jobs.wake_event:
				finish_jobs(&app)
				redraw = true
			case u32(e.type) == app.player.events_event:
				if !player_handle_events(&app.player) {
					running = false
				}
			case u32(e.type) == app.player.redraw_event:
				if player_wants_redraw(&app.player) {
					app.new_video_frame = true
					redraw = true
				}
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

// Once the chat has joined, the channel's ID is known: load its emotes and badges.
joined :: proc(app: ^App, room_id: string) {
	if room_id == "" {
		return
	}
	app.room_id = strings.clone(room_id)
	for source in Emote_Source.Channel_7TV ..= Emote_Source.Channel_FFZ {
		emotes_request_set(&app.assets.jobs, source, room_id)
	}
	if app.signed_in {
		emotes_request_badges(&app.assets.jobs, app.client_id, app.auth, room_id)
	}
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
			finish_emote_set_job(&a.emotes, &p)
		case Badges_Job:
			finish_badges_job(&a.emotes, &p)
			switch p.check {
			case .Valid, .Unreachable:
			case .Refreshed:
				destroy_auth(app.auth)
				app.auth = clone_auth(p.auth)
				save_auth(app.auth)
			case .Signed_Out:
				destroy_auth(app.auth)
				app.auth = {}
				app.signed_in = false
			}
		}
		destroy_job(job)
	}
}

in_rect :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

chat_content_width :: proc(app: App) -> f32 {
	return app.chat_rect.w - 2 * CHAT_PADDING * app.scale
}

draw :: proc(app: ^App) {
	a := &app.assets
	w, h: i32
	sdl.GetWindowSizeInPixels(app.window, &w, &h)
	app.scale = sdl.GetWindowDisplayScale(app.window)
	a.now_ms = int(sdl.GetTicks())

	chat_w := min(f32(i32(CHAT_WIDTH * app.scale)), f32(w) / 2) if app.show_chat else 0
	video := Rect{0, 0, f32(w) - chat_w, f32(h)}
	app.chat_rect = {video.w, 0, chat_w, f32(h)}

	// A resize draws the frame again at the new size.
	video_size := [2]i32{i32(video.w), i32(video.h)}
	if video_size != app.player.target_size {
		player_resize(&app.player, video_size)
	} else if app.new_video_frame {
		player_render(&app.player)
	}
	app.new_video_frame = false

	// The font atlas can grow mid-frame, which needs one more pass.
	for _ in 0 ..< 2 {
		a.next_frame_ms = -1
		renderer_begin(&a.renderer, w, h)
		gl.ClearColor(0, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		draw_image(&a.renderer, app.player.texture, video)
		if app.show_chat {
			draw_chat_view(a, &app.chat_view, app.chat_rect, app.scale)
		}
		if renderer_end(&a.renderer) {
			break
		}
	}
	sdl.GL_SwapWindow(app.window)
	player_report_swap(&app.player)
}
