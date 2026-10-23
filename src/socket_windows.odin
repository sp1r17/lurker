package app

import win "core:sys/windows"
import "vendor:curl"

// Waits until `sock` has data to read, or `timeout_ms` passes.
wait_readable :: proc(sock: curl.socket_t, timeout_ms: int) {
	fds := [1]win.WSA_POLLFD{{fd = win.SOCKET(sock), events = win.POLLIN}}
	win.WSAPoll(&fds[0], 1, i32(timeout_ms))
}
