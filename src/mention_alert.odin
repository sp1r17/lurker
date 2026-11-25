package app

import "core:c"
import "core:log"
import "core:math"
import sdl "vendor:sdl3"

// Mentions and highlight phrases can play a sound and flash Lurker in the
// taskbar (Settings). The sound is a short chime made here, played through SDL
// rather than mpv, which only plays the stream. The audio device is opened for
// it and closed again once it's played, so Lurker isn't left holding it.

MENTION_SOUND_RATE :: 48000
// At most one chime in this long, however many mentions arrive.
MENTION_SOUND_GAP_MS :: 2000
// How long after a chime starts the audio device closes, past its end.
MENTION_SOUND_CLOSE_MS :: 1500

Mention_Alert :: struct {
	stream:  ^sdl.AudioStream,
	// When the device closes (Assets.now_ms), and the next chime can play.
	close_at: int,
	next_at:  int,
	// SDL's audio didn't start: no more tries this run.
	failed:   bool,
}

// A soft two-note chime, mono, as 32-bit float samples at MENTION_SOUND_RATE.
mention_chime :: proc(allocator := context.allocator) -> []f32 {
	Note :: struct {
		hz, start: f32,
	}
	notes := [2]Note{{880, 0}, {1318.5, 0.09}}
	length: f32 = 0.45
	n := int(length * MENTION_SOUND_RATE)
	out := make([]f32, n, allocator)
	for note in notes {
		for i in int(note.start * MENTION_SOUND_RATE) ..< n {
			t := f32(i) / MENTION_SOUND_RATE - note.start
			// A quick rise and a decay, with some of the octave above, like a bell.
			envelope := min(t / 0.005, 1) * math.exp(-t * 9)
			tone := math.sin(2 * math.PI * note.hz * t) + 0.25 * math.sin(4 * math.PI * note.hz * t)
			out[i] += 0.15 * envelope * tone
		}
	}
	// Faded out over the last 20 ms, so it doesn't end in a click.
	fade := int(0.02 * MENTION_SOUND_RATE)
	for i in 0 ..< fade {
		out[n - 1 - i] *= f32(i) / f32(fade)
	}
	return out
}

// `count` mentions (or highlight phrases) just arrived live: the sound, and the
// taskbar flash while Lurker isn't the focused window, as Settings has them.
mention_alert :: proc(app: ^App, count: int) {
	if count == 0 {
		return
	}
	chat := &app.layout.chat
	if chat.mention_flash && app.window != nil && .INPUT_FOCUS not_in sdl.GetWindowFlags(app.window) {
		_ = sdl.FlashWindow(app.window, .UNTIL_FOCUSED)
	}
	if chat.mention_sound {
		mention_sound_play(&app.mention_alert, app.assets.now_ms)
	}
}

@(private = "file")
mention_sound_play :: proc(m: ^Mention_Alert, now_ms: int) {
	if m.failed || now_ms < m.next_at {
		return
	}
	m.next_at = now_ms + MENTION_SOUND_GAP_MS
	if m.stream == nil {
		if !sdl.InitSubSystem({.AUDIO}) {
			log.warnf("mention sound: can't start audio: %s", sdl.GetError())
			m.failed = true
			return
		}
		spec := sdl.AudioSpec{.F32, 1, MENTION_SOUND_RATE}
		m.stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
		if m.stream == nil {
			log.warnf("mention sound: can't open the sound output: %s", sdl.GetError())
			sdl.QuitSubSystem({.AUDIO})
			m.failed = true
			return
		}
		_ = sdl.ResumeAudioStreamDevice(m.stream)
	}
	chime := mention_chime(context.temp_allocator)
	_ = sdl.PutAudioStreamData(m.stream, raw_data(chime), c.int(len(chime) * size_of(f32)))
	m.close_at = now_ms + MENTION_SOUND_CLOSE_MS
}

// Closes the audio device once the chime has played. Returns ms until that's
// due, or -1, for the main loop's wait.
mention_sound_tick :: proc(app: ^App) -> int {
	m := &app.mention_alert
	if m.stream == nil {
		return -1
	}
	if left := m.close_at - app.assets.now_ms; left > 0 {
		return left
	}
	mention_sound_close(m)
	return -1
}

mention_sound_close :: proc(m: ^Mention_Alert) {
	if m.stream != nil {
		sdl.DestroyAudioStream(m.stream)
		sdl.QuitSubSystem({.AUDIO})
		m.stream = nil
	}
}
