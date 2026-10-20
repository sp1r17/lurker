package app

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// How long streamlink gets to exit after being asked, before it's killed.
STREAMLINK_EXIT_WAIT :: 2 * time.Second

Stream_Error :: enum {
	None,
	Streamlink_Failed,
	Offline,
	// Played, then stopped: the broadcast is over.
	Ended,
}

// A streamlink process writing the channel's stream into a pipe that mpv reads.
// Going through streamlink rather than playing Twitch's URL directly is what skips
// the ads: streamlink drops ad segments from the stream it passes on.
Streamlink :: struct {
	process: os.Process,
	// The read end of streamlink's stderr, for why it stopped.
	errors:  ^os.File,
	// mpv's own copy of the stream pipe's read end; mpv closes it ("fdclose://").
	mpv_fd:  posix.FD,
	running: bool,
}

// Starts streamlink on `channel`. Play streamlink_url(s) in mpv.
streamlink_start :: proc(channel: string) -> (s: Streamlink, ok: bool) {
	video_r, video_w, pipe_err := os.pipe()
	if pipe_err != nil {
		return {}, false
	}
	errors_r, errors_w, errors_err := os.pipe()
	if errors_err != nil {
		os.close(video_r)
		os.close(video_w)
		return {}, false
	}
	process, start_err := os.process_start(
		{
			command = {"streamlink", "--stdout", "--loglevel", "error", fmt.tprintf("https://twitch.tv/%s", channel), "best"},
			stdout = video_w,
			stderr = errors_w,
		},
	)
	// The child has its own copies of the write ends.
	os.close(video_w)
	os.close(errors_w)
	if start_err != nil {
		log.errorf("can't run streamlink: %v", start_err)
		os.close(video_r)
		os.close(errors_r)
		return {}, false
	}

	// mpv reads on its own threads and finishes with the pipe after we've moved on,
	// so it gets a descriptor of its own to close, and ours closes now. Close-on-exec
	// keeps it out of later child processes.
	s.mpv_fd = posix.FD(posix.fcntl(posix.FD(os.fd(video_r)), .DUPFD_CLOEXEC, 0))
	os.close(video_r)
	s.process = process
	s.errors = errors_r
	s.running = true
	if s.mpv_fd < 0 {
		streamlink_stop(&s)
		return {}, false
	}
	return s, true
}

// What mpv should play.
streamlink_url :: proc(s: ^Streamlink) -> string {
	return fmt.tprintf("fdclose://%d", s.mpv_fd)
}

// Stops streamlink: asked first, then killed if it doesn't exit in time.
streamlink_stop :: proc(s: ^Streamlink) {
	if !s.running {
		return
	}
	s.running = false
	_ = os.process_terminate(s.process)
	if _, err := os.process_wait(s.process, STREAMLINK_EXIT_WAIT); err != nil {
		_ = os.process_kill(s.process)
		_, _ = os.process_wait(s.process)
	}
	os.close(s.errors)
}

// Why the stream stopped, once mpv has reached its end: streamlink's exit code and
// error output tell an offline channel from an ended broadcast or a failure.
streamlink_outcome :: proc(s: ^Streamlink) -> Stream_Error {
	if !s.running {
		return .Ended
	}
	state, err := os.process_wait(s.process, STREAMLINK_EXIT_WAIT)
	if err != nil {
		// Still running: mpv gave up on the stream, not streamlink.
		streamlink_stop(s)
		return .Streamlink_Failed
	}
	s.running = false
	output, _ := os.read_entire_file(s.errors, context.temp_allocator)
	os.close(s.errors)
	text := strings.trim_space(string(output))
	switch {
	case strings.contains(text, "No playable streams"):
		return .Offline
	case state.exit_code == 0:
		return .Ended
	case:
		log.errorf("streamlink failed: %s", text)
		return .Streamlink_Failed
	}
}
