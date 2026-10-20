package app

import "core:c"
import "core:log"
import sdl "vendor:sdl3"

// Dragging the borderless window from the video, as mpv does on Wayland: the app
// sees the press (so a double-click can toggle fullscreen), and only once the mouse
// moves does it ask the compositor to move the window.
//
// SDL's hit test can't do that: it hands every press in a draggable area to the
// compositor before the app sees it. Starting a move ourselves takes the seat and
// the press's serial, which SDL doesn't expose, so this binds its own wl_seat on
// SDL's connection, on its own event queue, and keeps its own wl_pointer's latest
// press serial. Any wl_seat object of the client is accepted for the request.

foreign import wl "system:wayland-client"

@(private = "file")
wl_proxy :: struct {}
@(private = "file")
wl_event_queue :: struct {}
@(private = "file")
wl_interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int,
	methods:      rawptr,
	event_count:  c.int,
	events:       rawptr,
}

@(private = "file", default_calling_convention = "c")
foreign wl {
	wl_registry_interface: wl_interface
	wl_seat_interface: wl_interface
	wl_pointer_interface: wl_interface

	wl_display_create_queue :: proc(display: ^wl_proxy) -> ^wl_event_queue ---
	wl_event_queue_destroy :: proc(queue: ^wl_event_queue) ---
	wl_proxy_create_wrapper :: proc(proxy: rawptr) -> rawptr ---
	wl_proxy_wrapper_destroy :: proc(wrapper: rawptr) ---
	wl_proxy_set_queue :: proc(proxy: ^wl_proxy, queue: ^wl_event_queue) ---
	wl_proxy_marshal_flags :: proc(proxy: ^wl_proxy, opcode: u32, interface: ^wl_interface, version: u32, flags: u32, #c_vararg args: ..any) -> ^wl_proxy ---
	wl_proxy_add_listener :: proc(proxy: ^wl_proxy, implementation: rawptr, data: rawptr) -> c.int ---
	wl_proxy_get_version :: proc(proxy: ^wl_proxy) -> u32 ---
	wl_proxy_destroy :: proc(proxy: ^wl_proxy) ---
	wl_display_roundtrip_queue :: proc(display: ^wl_proxy, queue: ^wl_event_queue) -> c.int ---
	wl_display_dispatch_queue_pending :: proc(display: ^wl_proxy, queue: ^wl_event_queue) -> c.int ---
	wl_display_flush :: proc(display: ^wl_proxy) -> c.int ---
}

// Request opcodes, from wayland.xml and xdg-shell.xml.
@(private = "file")
WL_DISPLAY_GET_REGISTRY :: 1
@(private = "file")
WL_REGISTRY_BIND :: 0
@(private = "file")
WL_SEAT_GET_POINTER :: 0
@(private = "file")
XDG_TOPLEVEL_MOVE :: 5
@(private = "file")
WL_SEAT_CAPABILITY_POINTER :: 1
@(private = "file")
BTN_LEFT :: 0x110
@(private = "file")
WL_POINTER_BUTTON_STATE_PRESSED :: 1

Wayland_Drag :: struct {
	display:    ^wl_proxy,
	toplevel:   ^wl_proxy,
	queue:      ^wl_event_queue,
	registry:   ^wl_proxy,
	seat:       ^wl_proxy,
	pointer:    ^wl_proxy,
	// The serial of the latest left-button press, for starting a move.
	press:      u32,
}

@(private = "file")
Registry_Listener :: struct {
	global:        proc "c" (data: rawptr, registry: ^wl_proxy, name: u32, interface: cstring, version: u32),
	global_remove: proc "c" (data: rawptr, registry: ^wl_proxy, name: u32),
}

@(private = "file")
Seat_Listener :: struct {
	capabilities: proc "c" (data: rawptr, seat: ^wl_proxy, caps: u32),
	name:         proc "c" (data: rawptr, seat: ^wl_proxy, name: cstring),
}

// wl_pointer version 1's events; the seat is bound at version 1, so no others come.
@(private = "file")
Pointer_Listener :: struct {
	enter:  proc "c" (data: rawptr, pointer: ^wl_proxy, serial: u32, surface: ^wl_proxy, x, y: i32),
	leave:  proc "c" (data: rawptr, pointer: ^wl_proxy, serial: u32, surface: ^wl_proxy),
	motion: proc "c" (data: rawptr, pointer: ^wl_proxy, time: u32, x, y: i32),
	button: proc "c" (data: rawptr, pointer: ^wl_proxy, serial: u32, time: u32, button: u32, state: u32),
	axis:   proc "c" (data: rawptr, pointer: ^wl_proxy, time: u32, axis: u32, value: i32),
}

@(private = "file")
registry_listener := Registry_Listener {
	global = proc "c" (data: rawptr, registry: ^wl_proxy, name: u32, interface: cstring, version: u32) {
		d := (^Wayland_Drag)(data)
		if d.seat != nil || interface != wl_seat_interface.name {
			return
		}
		d.seat = wl_proxy_marshal_flags(registry, WL_REGISTRY_BIND, &wl_seat_interface, 1, 0, name, wl_seat_interface.name, u32(1), rawptr(nil))
		wl_proxy_add_listener(d.seat, &seat_listener, d)
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl_proxy, name: u32) {},
}

@(private = "file")
seat_listener := Seat_Listener {
	capabilities = proc "c" (data: rawptr, seat: ^wl_proxy, caps: u32) {
		d := (^Wayland_Drag)(data)
		if d.pointer != nil || caps & WL_SEAT_CAPABILITY_POINTER == 0 {
			return
		}
		d.pointer = wl_proxy_marshal_flags(seat, WL_SEAT_GET_POINTER, &wl_pointer_interface, wl_proxy_get_version(seat), 0, rawptr(nil))
		wl_proxy_add_listener(d.pointer, &pointer_listener, d)
	},
	name = proc "c" (data: rawptr, seat: ^wl_proxy, name: cstring) {},
}

@(private = "file")
pointer_listener := Pointer_Listener {
	enter = proc "c" (data: rawptr, pointer: ^wl_proxy, serial: u32, surface: ^wl_proxy, x, y: i32) {},
	leave = proc "c" (data: rawptr, pointer: ^wl_proxy, serial: u32, surface: ^wl_proxy) {},
	motion = proc "c" (data: rawptr, pointer: ^wl_proxy, time: u32, x, y: i32) {},
	button = proc "c" (data: rawptr, pointer: ^wl_proxy, serial: u32, time: u32, button: u32, state: u32) {
		if button == BTN_LEFT && state == WL_POINTER_BUTTON_STATE_PRESSED {
			(^Wayland_Drag)(data).press = serial
		}
	},
	axis = proc "c" (data: rawptr, pointer: ^wl_proxy, time: u32, axis: u32, value: i32) {},
}

// Sets up dragging for `window`. False if it isn't a Wayland window or the seat
// has no pointer; the caller falls back to SDL's hit test then.
wayland_drag_init :: proc(d: ^Wayland_Drag, window: ^sdl.Window) -> bool {
	props := sdl.GetWindowProperties(window)
	d.display = (^wl_proxy)(sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil))
	d.toplevel = (^wl_proxy)(sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_POINTER, nil))
	if d.display == nil || d.toplevel == nil {
		return false
	}
	// Our own queue: SDL reads the connection and our events wait here until we
	// dispatch them, never running inside SDL's dispatch.
	d.queue = wl_display_create_queue(d.display)
	wrapper := (^wl_proxy)(wl_proxy_create_wrapper(d.display))
	wl_proxy_set_queue(wrapper, d.queue)
	d.registry = wl_proxy_marshal_flags(wrapper, WL_DISPLAY_GET_REGISTRY, &wl_registry_interface, wl_proxy_get_version(wrapper), 0, rawptr(nil))
	wl_proxy_wrapper_destroy(wrapper)
	wl_proxy_add_listener(d.registry, &registry_listener, d)
	// One round trip for the seat, one for its capabilities.
	wl_display_roundtrip_queue(d.display, d.queue)
	wl_display_roundtrip_queue(d.display, d.queue)
	if d.pointer == nil {
		log.warn("no Wayland pointer; dragging falls back to SDL")
		wayland_drag_destroy(d)
		return false
	}
	return true
}

wayland_drag_destroy :: proc(d: ^Wayland_Drag) {
	if d.pointer != nil {
		wl_proxy_destroy(d.pointer)
	}
	if d.seat != nil {
		wl_proxy_destroy(d.seat)
	}
	if d.registry != nil {
		wl_proxy_destroy(d.registry)
	}
	if d.queue != nil {
		wl_event_queue_destroy(d.queue)
	}
	d^ = {}
}

// Handles our pointer's queued events (the press serials). Call once per loop so
// the queue doesn't grow.
wayland_drag_update :: proc(d: ^Wayland_Drag) {
	if d.queue != nil {
		wl_display_dispatch_queue_pending(d.display, d.queue)
	}
}

// Asks the compositor to move the window with the pointer, for the left button
// that's held down now.
wayland_drag_start :: proc(d: ^Wayland_Drag) {
	wayland_drag_update(d)
	if d.press == 0 {
		return
	}
	wl_proxy_marshal_flags(d.toplevel, XDG_TOPLEVEL_MOVE, nil, wl_proxy_get_version(d.toplevel), 0, d.seat, d.press)
	wl_display_flush(d.display)
}
