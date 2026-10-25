package app

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

// How long streamlink gets to exit by itself once mpv has reached the stream's end.
STREAMLINK_EXIT_WAIT_MS :: 2000
// Where streamlink serves the stream over HTTP (STREAMLINK_SERVES_HTTP): how long
// it gets to start serving, and how often mpv tries it meanwhile.
STREAMLINK_HTTP_WAIT_MS :: 15_000
STREAMLINK_HTTP_RETRY_MS :: 500

Stream_Error :: enum {
	None,
	Streamlink_Failed,
	Offline,
	// Played, then stopped: the broadcast is over.
	Ended,
}

// A streamlink process passing the channel's stream on to mpv, through a pipe or
// a local HTTP server (stream_linux.odin, stream_windows.odin). Going through
// streamlink rather than playing Twitch's URL directly is what skips the ads:
// streamlink drops ad segments from the stream it passes on.
Streamlink :: struct {
	process: os.Process,
	// The read end of streamlink's stderr, for why it stopped.
	errors:  ^os.File,
	output:  Stream_Output,
	running: bool,
}

// Starts streamlink on `channel`. Play streamlink_url(s) in mpv. With a `token`,
// streamlink asks Twitch for the stream as that user, so their Turbo or channel
// subscription can remove the ads at the source. The token is tied to `client_id`,
// so that's sent too, replacing the website client ID streamlink sends by default.
// With `low_latency`, streamlink stays close to the live edge: it fetches segments
// before they're complete and keeps only two behind (--twitch-low-latency).
streamlink_start :: proc(
	channel: string,
	quality: Quality,
	low_latency: bool,
	client_id := "",
	token := "",
) -> (
	s: Streamlink,
	ok: bool,
) {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, streamlink_program(), "--loglevel", "error")
	append(&command, "--twitch-supported-codecs", quality_codecs(quality))
	if low_latency {
		append(&command, "--twitch-low-latency")
	}
	if token != "" {
		config, config_ok := write_streamlink_config(client_id, token)
		if !config_ok {
			return {}, false
		}
		append(&command, "--config", config)
	}
	output := stream_output_args(&command) or_return
	append(&command, fmt.tprintf("https://twitch.tv/%s", channel), QUALITY_STREAMS[quality])
	return streamlink_spawn(command[:], output)
}

// Writes the sign-in for streamlink to a config file only the user can read:
// arguments would show the token to everyone on the machine (ps). Returns its path,
// allocated with the temp allocator.
@(private = "file")
write_streamlink_config :: proc(client_id, token: string) -> (path: string, ok: bool) {
	auth_file := auth_path() or_return
	dir := filepath.dir(auth_file)
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		return "", false
	}
	joined, join_err := filepath.join({dir, "streamlink.conf"}, context.temp_allocator)
	if join_err != nil {
		return "", false
	}
	config := fmt.tprintf(
		"twitch-api-header=Authorization=OAuth %s\ntwitch-api-header=Client-ID=%s\n",
		token,
		client_id,
	)
	if err := os.write_entire_file(joined, config, {.Read_User, .Write_User}); err != nil {
		log.errorf("can't write %s: %v", joined, err)
		return "", false
	}
	return joined, true
}

// The address of past broadcast `vod_id`'s video, which mpv plays directly (so it
// can seek), from streamlink. Blocks while streamlink looks it up: for a job. With
// a `token`, subscriber-only broadcasts work too. Allocated with `allocator`.
streamlink_vod_url :: proc(vod_id: string, kind: Video_Kind, quality: Quality, client_id := "", token := "", allocator := context.allocator) -> (url: string, ok: bool) {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, streamlink_program(), "--stream-url", "--loglevel", "error")
	append(&command, "--twitch-supported-codecs", quality_codecs(quality))
	if token != "" {
		config := write_streamlink_config(client_id, token) or_return
		append(&command, "--config", config)
	}
	page := fmt.tprintf("https://clips.twitch.tv/%s", vod_id) if kind == .Clip else fmt.tprintf("https://www.twitch.tv/videos/%s", vod_id)
	append(&command, page, QUALITY_STREAMS[quality])
	state, stdout, stderr, err := os.process_exec({command = command[:]}, context.temp_allocator)
	if err != nil {
		log.errorf("can't run streamlink: %v", err)
		return "", false
	}
	out := strings.trim_space(string(stdout))
	if state.exit_code != 0 || !strings.has_prefix(out, "https://") {
		log.errorf("streamlink can't find the broadcast: %s", strings.trim_space(string(stderr)))
		return "", false
	}
	return strings.clone(out, allocator), true
}

// Stops streamlink: asked first, then killed if it doesn't exit in time.
streamlink_stop :: proc(s: ^Streamlink) {
	if !s.running {
		return
	}
	s.running = false
	// Killed outright: asked to stop (SIGTERM) mid-stream, streamlink took 1 to
	// over 10 seconds winding down its download threads, with the window frozen
	// waiting. It only passes the stream on, so there's nothing to lose.
	_ = os.process_kill(s.process)
	_, _ = os.process_wait(s.process)
	os.close(s.errors)
}

// Why the stream stopped, once mpv has reached its end: streamlink's exit code and
// error output tell an offline channel from an ended broadcast or a failure. Doesn't
// wait: `done` is false while streamlink is still running.
streamlink_outcome :: proc(s: ^Streamlink) -> (outcome: Stream_Error, done: bool) {
	if !s.running {
		return .Ended, true
	}
	state, err := os.process_wait(s.process, 0)
	if err == .Timeout {
		return .None, false
	}
	if err != nil {
		streamlink_stop(s)
		return .Streamlink_Failed, true
	}
	s.running = false
	output, _ := os.read_entire_file(s.errors, context.temp_allocator)
	os.close(s.errors)
	text := strings.trim_space(string(output))
	switch {
	case strings.contains(text, "No playable streams"):
		return .Offline, true
	case state.exit_code == 0:
		return .Ended, true
	case:
		log.errorf("streamlink failed: %s", text)
		return .Streamlink_Failed, true
	}
}

// A broadcast still being recorded has a growing playlist, which mpv plays like
// a live stream: from its end, without seeking. This saves a copy as it is now,
// with its segments' full addresses and marked as finished, which mpv plays like
// any past broadcast. Returns its path, allocated with the temp allocator.
snapshot_recording :: proc(url: string) -> (path: string, ok: bool) {
	res := http_request(url, allocator = context.temp_allocator) or_return
	if res.status != 200 {
		log.warnf("can't fetch the recording's playlist: HTTP %d", res.status)
		return "", false
	}
	playlist, playlist_ok := finished_playlist(string(res.body), url)
	if !playlist_ok {
		log.warn("the recording's playlist isn't one")
		return "", false
	}
	dir := cache_dir() or_return
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		return "", false
	}
	joined, join_err := filepath.join({dir, "recording.m3u8"}, context.temp_allocator)
	if join_err != nil {
		return "", false
	}
	if err := os.write_entire_file(joined, playlist); err != nil {
		log.warnf("can't write %s: %v", joined, err)
		return "", false
	}
	return joined, true
}

// `playlist` (an HLS media playlist fetched from `url`) as a finished one, with
// its segments' addresses made full. Allocated with the temp allocator.
finished_playlist :: proc(playlist, url: string) -> (out: string, ok: bool) {
	if !strings.has_prefix(playlist, "#EXTM3U") {
		return "", false
	}
	base := url[:strings.last_index_byte(url, '/') + 1]
	sb := strings.builder_make(context.temp_allocator)
	rest := playlist
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		switch {
		case line == "#EXT-X-PLAYLIST-TYPE:EVENT":
			strings.write_string(&sb, "#EXT-X-PLAYLIST-TYPE:VOD")
		case line == "#EXT-X-ENDLIST":
			continue
		case line != "" && !strings.has_prefix(line, "#") && !strings.contains(line, "://"):
			strings.write_string(&sb, base)
			strings.write_string(&sb, line)
		case:
			strings.write_string(&sb, line)
		}
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, "#EXT-X-ENDLIST\n")
	return strings.to_string(sb), true
}
