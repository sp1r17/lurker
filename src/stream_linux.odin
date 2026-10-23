package app

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"

// streamlink writes the stream into a pipe that mpv reads; when the stream ends,
// mpv sees the end of the pipe.
STREAMLINK_SERVES_HTTP :: false

// mpv's own copy of the stream pipe's read end; mpv closes it ("fdclose://").
Stream_Output :: struct {
	mpv_fd: posix.FD,
}

// streamlink from the PATH: the system's, or the Flatpak's.
streamlink_program :: proc() -> string {
	return "streamlink"
}

// Adds the arguments that send the stream to mpv.
stream_output_args :: proc(command: ^[dynamic]string) -> (out: Stream_Output, ok: bool) {
	append(command, "--stdout")
	return {}, true
}

// Runs `command`, its stdout into a pipe for mpv and its stderr into one for errors.
streamlink_spawn :: proc(command: []string, out: Stream_Output) -> (s: Streamlink, ok: bool) {
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
	process, start_err := os.process_start({command = command, stdout = video_w, stderr = errors_w})
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
	s.output.mpv_fd = posix.FD(posix.fcntl(posix.FD(os.fd(video_r)), .DUPFD_CLOEXEC, 0))
	os.close(video_r)
	s.process = process
	s.errors = errors_r
	s.running = true
	if s.output.mpv_fd < 0 {
		streamlink_stop(&s)
		return {}, false
	}
	return s, true
}

// What mpv should play.
streamlink_url :: proc(s: ^Streamlink) -> string {
	return fmt.tprintf("fdclose://%d", s.output.mpv_fd)
}
