package app

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"

// mpv can't read a pipe by descriptor here, so streamlink serves the stream over
// HTTP on the loopback interface, and mpv plays that. The server starts a moment
// after streamlink does, and stays up after the broadcast ends (see
// watch_stream_ended).
STREAMLINK_SERVES_HTTP :: true

// The loopback port streamlink serves the stream on.
Stream_Output :: struct {
	port: int,
}

// The streamlink bundled beside lurker.exe (streamlink\bin, from the portable
// Windows build), or else one on the PATH. streamlinkw.exe is its windowed
// launcher: streamlink.exe would open a console window each time it's run.
streamlink_program :: proc() -> string {
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		bundled, join_err := filepath.join({dir, "streamlink", "bin", "streamlinkw.exe"}, context.temp_allocator)
		if join_err == nil && os.exists(bundled) {
			return bundled
		}
	}
	return "streamlink"
}

// Adds the arguments that serve the stream on a free loopback port.
stream_output_args :: proc(command: ^[dynamic]string) -> (out: Stream_Output, ok: bool) {
	out.port = free_port() or_return
	append(
		command,
		"--player-external-http",
		"--player-external-http-interface",
		"127.0.0.1",
		"--player-external-http-port",
		fmt.tprint(out.port),
	)
	return out, true
}

// A loopback port nothing is listening on, found by letting the system pick one.
// Another program could take it before streamlink does, but that's unlikely.
@(private = "file")
free_port :: proc() -> (port: int, ok: bool) {
	socket, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		log.errorf("can't find a free port for streamlink: %v", err)
		return 0, false
	}
	defer net.close(socket)
	endpoint, endpoint_err := net.bound_endpoint(socket)
	if endpoint_err != nil {
		return 0, false
	}
	return endpoint.port, true
}

// Runs `command`, its stderr into a pipe for errors.
streamlink_spawn :: proc(command: []string, out: Stream_Output) -> (s: Streamlink, ok: bool) {
	errors_r, errors_w, errors_err := os.pipe()
	if errors_err != nil {
		return {}, false
	}
	process, start_err := os.process_start({command = command, stderr = errors_w})
	os.close(errors_w)
	if start_err != nil {
		log.errorf("can't run streamlink: %v", start_err)
		os.close(errors_r)
		return {}, false
	}
	s.process = process
	s.errors = errors_r
	s.output = out
	s.running = true
	return s, true
}

// What mpv should play.
streamlink_url :: proc(s: ^Streamlink) -> string {
	return fmt.tprintf("http://127.0.0.1:%d/", s.output.port)
}
