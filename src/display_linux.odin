package app

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:log"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import sdl "vendor:sdl3"

// Lurker quits when it loses its display (the compositor or X server quit or
// crashed), instead of running on unseen with a core busy and the stream playing.
// It quits at once, since the main thread may be stuck in SDL or Xlib by then; what
// Lurker saves is written when it changes, and a video's position at least once a
// minute.

foreign import wl "system:wayland-client"

@(private = "file", default_calling_convention = "c")
foreign wl {
	wl_display_get_fd :: proc(display: rawptr) -> c.int ---
}

// For x_io_error, which Xlib calls without Odin's context.
@(private = "file")
x_io_logger: log.Logger

display_watch :: proc(window: ^sdl.Window) {
	props := sdl.GetWindowProperties(window)
	if display := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil); display != nil {
		fd := linux.Fd(wl_display_get_fd(display))
		// The thread waits until Lurker ends, so it's never freed: not from the
		// allocator that debug builds check for leaks.
		thread_context := context
		context.allocator = runtime.heap_allocator()
		thread.create_and_start_with_poly_data(fd, watch_wayland, thread_context, name = "display watch")
		return
	}
	if sdl.GetCurrentVideoDriver() != "x11" {
		return
	}
	// SDL loaded libX11 already; this is the same library, not a dependency.
	lib, ok := dynlib.load_library("libX11.so.6")
	if !ok {
		return
	}
	set_handler, found := dynlib.symbol_address(lib, "XSetIOErrorHandler")
	if !found {
		return
	}
	x_io_logger = context.logger
	(proc "c" (handler: proc "c" (display: rawptr) -> c.int) -> rawptr)(set_handler)(x_io_error)
}

// Waits for the compositor to hang up. SDL doesn't notice: its buffer swap loops
// forever on a broken connection (SDL_waylandframebuffer.c,
// Wayland_WaitForSwapInterval), so this can't be left to the main thread.
@(private = "file")
watch_wayland :: proc(fd: linux.Fd) {
	for {
		fds := []linux.Poll_Fd{{fd = fd, events = {.RDHUP}}}
		_, err := linux.poll(fds, -1)
		if err == .EINTR {
			continue
		}
		if err != nil || fds[0].revents & {.RDHUP, .HUP, .ERR, .NVAL} == {} {
			return
		}
		log.error("lost the connection to the Wayland compositor; quitting")
		posix._exit(1)
	}
}

// Xlib's own handler calls exit(), which can hang in other libraries' exit
// handlers that use the dead connection.
@(private = "file")
x_io_error :: proc "c" (display: rawptr) -> c.int {
	context = runtime.default_context()
	context.logger = x_io_logger
	log.error("lost the connection to the X server; quitting")
	posix._exit(1)
}
