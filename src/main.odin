package app

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
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
	if !run(strings.to_lower(os.args[1], context.temp_allocator)) {
		os.exit(1)
	}
}

run :: proc(channel: string) -> bool {
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
	window := sdl.CreateWindow(title, 1280, 720, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
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

	player: Player
	if player_init(&player) != .None {
		return false
	}
	defer player_destroy(&player)
	player_load(&player, url)

	fullscreen := false
	draw(window, &player)
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
					player_command(&player, {"cycle", "pause"})
				case sdl.K_M:
					player_command(&player, {"cycle", "mute"})
				case sdl.K_UP:
					player_command(&player, {"add", "volume", VOLUME_STEP})
				case sdl.K_DOWN:
					player_command(&player, {"add", "volume", "-" + VOLUME_STEP})
				case sdl.K_F:
					fullscreen = !fullscreen
					sdl.SetWindowFullscreen(window, fullscreen)
				}
			case u32(e.type) == player.events_event:
				if !player_handle_events(&player) {
					running = false
				}
			case u32(e.type) == player.redraw_event:
				if player_wants_redraw(&player) {
					redraw = true
				}
			}
			if !sdl.PollEvent(&e) {
				break
			}
		}
		if redraw && running {
			draw(window, &player)
		}
	}
	return true
}

draw :: proc(window: ^sdl.Window, player: ^Player) {
	w, h: i32
	sdl.GetWindowSizeInPixels(window, &w, &h)
	gl.Viewport(0, 0, w, h)
	gl.ClearColor(0, 0, 0, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	player_draw(player, w, h)
	sdl.GL_SwapWindow(window)
	player_report_swap(player)
}
