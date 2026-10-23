package app

import "core:sys/posix"
import "vendor:curl"

// Waits until `sock` has data to read, or `timeout_ms` passes.
wait_readable :: proc(sock: curl.socket_t, timeout_ms: int) {
	fds := [1]posix.pollfd{{fd = posix.FD(sock), events = {.IN}}}
	posix.poll(&fds[0], 1, i32(timeout_ms))
}
