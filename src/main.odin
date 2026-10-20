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

	if len(os.args) != 2 || !valid_login(os.args[1]) {
		fmt.eprintfln("usage: %s <channel>", os.args[0])
		os.exit(2)
	}
	// Not temp-allocated: the chat thread uses it for the whole run.
	channel := strings.to_lower(os.args[1])
	ok := run(channel)
	delete(channel)
	if !ok {
		os.exit(1)
	}
}

run :: proc(channel: string) -> bool {
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK {
		log.error("curl init failed")
		return false
	}
	defer curl.global_cleanup()

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
	if !renderer_init(&app.renderer) {
		return false
	}
	defer renderer_destroy(&app.renderer)

	if player_init(&app.player) != .None {
		return false
	}
	defer player_destroy(&app.player)
	player_load(&app.player, url)

	chat: Chat
	chat_start(&chat, channel, sdl.RegisterEvents(1))
	defer chat_stop(&chat)
	defer chat_view_destroy(&app.chat_view)
	app.show_chat = true

	fullscreen := false
	draw(&app)
	for running := true; running; {
		defer free_all(context.temp_allocator)

		e: sdl.Event
		if !sdl.WaitEvent(&e) {
			log.errorf("waiting for events failed: %s", sdl.GetError())
			return false
		}
		redraw := false
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
				chat_view_add(&app.chat_view, &app.renderer, app.scale, chat_content_width(app), arrived[:])
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

App :: struct {
	window:          ^sdl.Window,
	renderer:        Renderer,
	player:          Player,
	chat_view:       Chat_View,
	show_chat:       bool,
	new_video_frame: bool,
	// From the last draw, in pixels.
	scale:           f32,
	chat_rect:       Rect,
}

in_rect :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

chat_content_width :: proc(app: App) -> f32 {
	return app.chat_rect.w - 2 * CHAT_PADDING * app.scale
}

draw :: proc(app: ^App) {
	w, h: i32
	sdl.GetWindowSizeInPixels(app.window, &w, &h)
	app.scale = sdl.GetWindowDisplayScale(app.window)

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
		renderer_begin(&app.renderer, w, h)
		gl.ClearColor(0, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		draw_image(&app.renderer, app.player.texture, video)
		if app.show_chat {
			draw_chat_view(&app.renderer, &app.chat_view, app.chat_rect, app.scale)
		}
		if renderer_end(&app.renderer) {
			break
		}
	}
	sdl.GL_SwapWindow(app.window)
	player_report_swap(&app.player)
}
