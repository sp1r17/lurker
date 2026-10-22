package app

import "core:log"
import "core:strings"
import "mpv"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

// Embedded mpv, drawing into the window's OpenGL context through libmpv's render API.
// mpv calls back from its own threads; the callbacks only push SDL events, and the
// main thread does the work when they arrive.
Player :: struct {
	handle:        ^mpv.Handle,
	render:        ^mpv.Render_Context,
	// SDL event types pushed when mpv has events waiting or a new frame to draw.
	events_event:  u32,
	redraw_event:  u32,
	// mpv draws into this texture, which the renderer then draws into the window.
	fbo:           u32,
	texture:       u32,
	target_size:   [2]i32,
}

Player_Error :: enum {
	None,
	Create_Failed,
	Init_Failed,
	Render_Init_Failed,
}

// Must be called with the window's OpenGL context current.
player_init :: proc(p: ^Player) -> Player_Error {
	first := sdl.RegisterEvents(2)
	p.events_event = first
	p.redraw_event = first + 1

	p.handle = mpv.create()
	if p.handle == nil {
		return .Create_Failed
	}
	mpv.set_option_string(p.handle, "vo", "libmpv")
	mpv.set_option_string(p.handle, "hwdec", "auto-safe")
	// "warn" includes a harmless ffmpeg warning for every Twitch segment.
	mpv.request_log_messages(p.handle, "error")
	if err := mpv.initialize(p.handle); err < 0 {
		log.errorf("mpv init failed: %s", mpv.error_string(err))
		mpv.terminate_destroy(p.handle)
		return .Init_Failed
	}

	gl_init := mpv.Opengl_Init_Params {
		get_proc_address = proc "c" (_: rawptr, name: cstring) -> rawptr {
			return rawptr(sdl.GL_GetProcAddress(name))
		},
	}
	api_type: cstring = mpv.RENDER_API_TYPE_OPENGL
	params := [?]mpv.Render_Param {
		{.Api_Type, rawptr(api_type)},
		{.Opengl_Init_Params, &gl_init},
		{},
	}
	if err := mpv.render_context_create(&p.render, p.handle, raw_data(params[:])); err < 0 {
		log.errorf("mpv render init failed: %s", mpv.error_string(err))
		mpv.terminate_destroy(p.handle)
		return .Render_Init_Failed
	}

	mpv.set_wakeup_callback(p.handle, push_event, rawptr(uintptr(p.events_event)))
	mpv.render_context_set_update_callback(p.render, push_event, rawptr(uintptr(p.redraw_event)))
	return .None
}

@(private = "file")
push_event :: proc "c" (event_type: rawptr) {
	e: sdl.Event
	e.type = sdl.EventType(u32(uintptr(event_type)))
	// Fails only when SDL's event queue is full; mpv calls again with its next event.
	_ = sdl.PushEvent(&e)
}

// Must be called with the window's OpenGL context current.
player_destroy :: proc(p: ^Player) {
	// The render context goes first: it holds GL objects and keeps the core alive.
	mpv.render_context_free(p.render)
	mpv.terminate_destroy(p.handle)
	gl.DeleteFramebuffers(1, &p.fbo)
	gl.DeleteTextures(1, &p.texture)
}

// mpv's built-in low-latency profile, minus single-threaded decoding (which can
// drop frames at 1080p60) and skipping stream probing (which could miss the audio
// in what streamlink sends), plus no cache.
LOW_LATENCY_OPTIONS :: "cache=no,cache-pause=no,audio-buffer=0,stream-buffer-size=4k,demuxer-lavf-o-add=fflags=+nobuffer,demuxer-lavf-analyzeduration=0.1,video-sync=audio,interpolation=no,video-latency-hacks=yes"

// Plays `url`. With `low_latency`, mpv buffers as little as it can; the options
// apply to this file only, so they're gone with the next.
player_load :: proc(p: ^Player, url: string, low_latency := false) {
	curl := strings.clone_to_cstring(url, context.temp_allocator)
	if low_latency {
		player_command(p, {"loadfile", curl, "replace", "-1", LOW_LATENCY_OPTIONS})
	} else {
		player_command(p, {"loadfile", curl})
	}
}

player_command :: proc(p: ^Player, args: []cstring) {
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	copy(argv, args)
	if err := mpv.command_async(p.handle, 0, raw_data(argv)); err < 0 {
		log.warnf("mpv command %v failed: %s", args, mpv.error_string(err))
	}
}

Player_Event :: enum {
	Shutdown,
	// The stream's first frame is ready to show. ("file-loaded" comes before
	// that: the texture would still hold the last stream's frame.)
	Playing,
	// The stream reached its end, or failed (the reason is logged).
	Ended,
}
Player_Events :: bit_set[Player_Event]

// Handles mpv's waiting events, returning the ones the app acts on.
player_handle_events :: proc(p: ^Player) -> (events: Player_Events) {
	for {
		e := mpv.wait_event(p.handle, 0)
		#partial switch e.event_id {
		case .None:
			return
		case .Shutdown:
			events += {.Shutdown}
			return
		case .Playback_Restart:
			events += {.Playing}
		case .Log_Message:
			m := (^mpv.Event_Log_Message)(e.data)
			log.warnf("mpv %s: %s", m.prefix, strings.trim_right_space(string(m.text)))
		case .End_File:
			end := (^mpv.Event_End_File)(e.data)
			// .Stop is us stopping it; not an end to report.
			#partial switch end.reason {
			case .Error:
				log.warnf("playback stopped: %s", mpv.error_string(end.error))
				events += {.Ended}
			case .EOF:
				events += {.Ended}
			}
		case .Command_Reply:
			if e.error < 0 {
				log.warnf("mpv command failed: %s", mpv.error_string(e.error))
			}
		}
	}
}

// Whether mpv has a new frame since the last draw.
player_wants_redraw :: proc(p: ^Player) -> bool {
	return .Frame in mpv.render_context_update(p.render)
}

// Sizes the texture mpv draws into, and draws the current frame into it again.
player_resize :: proc(p: ^Player, size: [2]i32) {
	if size == p.target_size {
		return
	}
	if p.texture == 0 {
		gl.GenFramebuffers(1, &p.fbo)
		gl.GenTextures(1, &p.texture)
	}
	gl.BindTexture(gl.TEXTURE_2D, p.texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, size.x, size.y, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.BindFramebuffer(gl.FRAMEBUFFER, p.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, p.texture, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	p.target_size = size
	player_render(p)
}

// Clears the player's texture to black. Rendering can't do it when a stream stops:
// mpv takes "stop" asynchronously, so it would draw the stopped stream's last
// frame again.
player_clear :: proc(p: ^Player) {
	if p.texture == 0 {
		return
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, p.fbo)
	gl.ClearColor(0, 0, 0, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// Draws mpv's current frame into the player's texture.
player_render :: proc(p: ^Player) {
	if p.texture == 0 {
		return
	}
	fbo := mpv.Opengl_Fbo {
		fbo = i32(p.fbo),
		w   = p.target_size.x,
		h   = p.target_size.y,
	}
	// Unflipped, the texture's first row is the image's top, which is how the
	// renderer maps textures.
	flip_y: i32 = 0
	params := [?]mpv.Render_Param{{.Opengl_Fbo, &fbo}, {.Flip_Y, &flip_y}, {}}
	mpv.render_context_render(p.render, raw_data(params[:]))
}

player_report_swap :: proc(p: ^Player) {
	mpv.render_context_report_swap(p.render)
}
