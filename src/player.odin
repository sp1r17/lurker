package app

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"
import "mpv"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

// Embedded mpv, drawing into the window's OpenGL context through libmpv's render API.
// mpv calls back from its own threads; the callbacks only push SDL events, and the
// main thread does the work when they arrive.
//
// The main thread renders, so it must never wait on mpv's core (render.h,
// "Threading"): a stuck core would freeze the window. Commands are async, and
// what's playing comes from observed properties rather than mpv_get_property.
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
	// What's playing, as mpv last reported it; nil while it has no value.
	position:      Maybe(f64),
	duration:      Maybe(f64),
	paused:        bool,
	// For the stream stats (stream_stats.odin).
	stats:         Player_Stats,
}

// How playback is going, as mpv last reported it, for the stream stats. Reset
// with each file played; nil while mpv has no value.
Player_Stats :: struct {
	height:          Maybe(i64),
	fps:             Maybe(f64),
	// mpv's names ("h264"; "vaapi", "no"). Owned.
	codec:           string,
	hwdec:           string,
	// Bits per second, as the demuxer measures them.
	video_bitrate:   Maybe(f64),
	audio_bitrate:   Maybe(f64),
	// Bytes per second coming in, now; and in all, since the file was loaded
	// (time.tick_now), which gives the average.
	net_speed:       Maybe(f64),
	received:        f64,
	loaded_at:       time.Tick,
	speed_at:        time.Tick,
	// Seconds buffered ahead.
	buffer:          Maybe(f64),
	// Frames dropped to keep up: by the video output, and by the decoder.
	dropped:         i64,
	decoder_dropped: i64,
}

@(private = "file")
STATS_PROPERTIES := [?]struct {
	name:   cstring,
	format: mpv.Format,
} {
	{"video-params/h", .Int64},
	{"estimated-vf-fps", .Double},
	{"video-format", .String},
	{"hwdec-current", .String},
	{"video-bitrate", .Double},
	{"audio-bitrate", .Double},
	{"cache-speed", .Double},
	{"demuxer-cache-duration", .Double},
	{"frame-drop-count", .Int64},
	{"decoder-frame-drop-count", .Int64},
}

@(private = "file")
stats_reset :: proc(s: ^Player_Stats) {
	delete(s.codec)
	delete(s.hwdec)
	s^ = {}
	s.loaded_at = time.tick_now()
	s.speed_at = s.loaded_at
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
	when ODIN_OS == .Linux {
		// Through pipewire-pulse rather than PipeWire directly: mpv 0.41's PipeWire
		// output can hang for good while closing when the audio graph changes,
		// taking mpv's core with it. The trailing comma falls back to the others.
		mpv.set_option_string(p.handle, "ao", "pulse,")
	}
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

	mpv.observe_property(p.handle, 0, "time-pos", .Double)
	mpv.observe_property(p.handle, 0, "duration", .Double)
	mpv.observe_property(p.handle, 0, "pause", .Flag)
	for prop in STATS_PROPERTIES {
		mpv.observe_property(p.handle, 0, prop.name, prop.format)
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
	stats_reset(&p.stats)
	gl.DeleteFramebuffers(1, &p.fbo)
	gl.DeleteTextures(1, &p.texture)
}

// mpv's built-in low-latency profile, minus single-threaded decoding (which can
// drop frames at 1080p60) and skipping stream probing (which could miss the audio
// in what streamlink sends). With no buffer, no cache either.
LOW_LATENCY_OPTIONS :: "audio-buffer=0,stream-buffer-size=4k,demuxer-lavf-o-add=fflags=+nobuffer,demuxer-lavf-analyzeduration=0.1,video-sync=audio,interpolation=no,video-latency-hacks=yes"

// The buffers low latency offers (Layout.latency_buffer_ms), in ms: none, or
// that much video waited for before playing, which then stays in hand to ride
// out the stream arriving unevenly. Streamlink's first segments come in a burst
// of about a second, so a smaller one would change nothing; above that, each
// second more is about a second further behind (measured: 1.5 s behind with
// none, 2.5 s with 2 s, 3.5 s with 3 s).
LOW_LATENCY_BUFFERS :: [?]int{0, 2000, 3000, 4000}

// What mpv does to the picture (Layout.video_enhancement).
Video_Enhancement :: enum {
	Off,
	// Debanding, against the banding Twitch's compression leaves in skies and
	// gradients, and sharper scaling than mpv's default.
	Balanced,
}

VIDEO_ENHANCEMENT_LABELS :: [Video_Enhancement]string {
	.Off      = "Off",
	.Balanced = "Balanced",
}

// Debanding with mpv's default strength, and its sharpest scaler for both the
// picture and its colour, which Twitch sends at half the resolution.
@(private = "file")
BALANCED_OPTIONS :: "deband=yes,scale=ewa_lanczossharp,cscale=ewa_lanczossharp"

// The options for `v`, for this file only; "" for none.
video_options :: proc(v: Video_Enhancement) -> string {
	switch v {
	case .Off:
		return ""
	case .Balanced:
		return BALANCED_OPTIONS
	}
	return ""
}

// Plays `url`. With `low_latency`, mpv buffers as little as it can, or
// `buffer_ms` of video; `video` is what it does to the picture. The options
// apply to this file only, so they're gone with the next.
player_load :: proc(p: ^Player, url: string, low_latency := false, buffer_ms := 0, video := Video_Enhancement.Off) {
	stats_reset(&p.stats)
	options := make([dynamic]string, context.temp_allocator)
	if low_latency {
		cache := "cache=no,cache-pause=no"
		if buffer_ms > 0 {
			cache = fmt.tprintf("cache=yes,cache-pause=yes,cache-pause-initial=yes,cache-pause-wait=%.1f", f64(buffer_ms) / 1000)
		}
		append(&options, cache, LOW_LATENCY_OPTIONS)
	}
	if v := video_options(video); v != "" {
		append(&options, v)
	}
	load_with_options(p, url, options[:])
}

// Plays `url` from `start` seconds in (for a past broadcast). With
// `online_segments`, `url` is a local playlist whose segments are on the web,
// which FFmpeg only fetches from a local playlist when told to.
player_load_at :: proc(p: ^Player, url: string, start: f64, online_segments := false, video := Video_Enhancement.Off) {
	stats_reset(&p.stats)
	options := make([dynamic]string, context.temp_allocator)
	append(&options, fmt.tprintf("start=%.1f", start))
	if online_segments {
		// mpv's %length% quoting, for the commas in the value.
		whitelist :: "protocol_whitelist=[file,http,https,tcp,tls,crypto]"
		append(&options, fmt.tprintf("demuxer-lavf-o-add=%%%d%%%s", len(whitelist), whitelist))
	}
	if v := video_options(video); v != "" {
		append(&options, v)
	}
	load_with_options(p, url, options[:])
}

// loadfile with per-file options, joined with commas.
@(private = "file")
load_with_options :: proc(p: ^Player, url: string, options: []string) {
	curl := strings.clone_to_cstring(url, context.temp_allocator)
	if len(options) == 0 {
		player_command(p, {"loadfile", curl})
		return
	}
	joined := strings.join(options, ",", context.temp_allocator)
	player_command(p, {"loadfile", curl, "replace", "-1", strings.clone_to_cstring(joined, context.temp_allocator)})
}

// Where playback is, in seconds, if anything's playing.
player_position :: proc(p: ^Player) -> (seconds: f64, ok: bool) {
	return p.position.?
}

// How long what's playing is, in seconds, if mpv knows.
player_duration :: proc(p: ^Player) -> (seconds: f64, ok: bool) {
	return p.duration.?
}

// Whether mpv is paused.
player_paused :: proc(p: ^Player) -> bool {
	return p.paused
}

@(private = "file")
property_changed :: proc(p: ^Player, prop: ^mpv.Event_Property) {
	number: Maybe(f64)
	integer: Maybe(i64)
	text: string
	#partial switch prop.format {
	case .Double:
		number = (^f64)(prop.data)^
	case .Int64:
		integer = (^i64)(prop.data)^
	case .String:
		text = string((^cstring)(prop.data)^)
	}
	s := &p.stats
	switch string(prop.name) {
	case "video-params/h":
		s.height = integer
	case "estimated-vf-fps":
		s.fps = number
	case "video-format":
		delete(s.codec)
		s.codec = strings.clone(text)
	case "hwdec-current":
		delete(s.hwdec)
		s.hwdec = strings.clone(text)
	case "video-bitrate":
		s.video_bitrate = number
	case "audio-bitrate":
		s.audio_bitrate = number
	case "cache-speed":
		// What came in since the last report, at the speed it reported.
		now := time.tick_now()
		if speed, ok := s.net_speed.?; ok {
			s.received += speed * time.duration_seconds(time.tick_diff(s.speed_at, now))
		}
		s.net_speed = number
		s.speed_at = now
	case "demuxer-cache-duration":
		s.buffer = number
	case "frame-drop-count":
		s.dropped = integer.? or_else 0
	case "decoder-frame-drop-count":
		s.decoder_dropped = integer.? or_else 0
	case "time-pos":
		p.position = number
	case "duration":
		p.duration = number
	case "pause":
		p.paused = prop.format == .Flag && (^i32)(prop.data)^ != 0
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
		case .Property_Change:
			property_changed(p, (^mpv.Event_Property)(e.data))
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
