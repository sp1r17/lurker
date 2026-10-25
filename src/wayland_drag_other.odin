#+build !linux
package app

import sdl "vendor:sdl3"

// Window dragging through Wayland is Linux-only (wayland_drag_linux.odin);
// elsewhere SDL's hit testing moves the borderless window (window_hit_test).
Wayland_Drag :: struct {}

wayland_drag_init :: proc(d: ^Wayland_Drag, window: ^sdl.Window) -> bool {
	return false
}

wayland_drag_destroy :: proc(d: ^Wayland_Drag) {}

wayland_drag_update :: proc(d: ^Wayland_Drag) {}

wayland_drag_start :: proc(d: ^Wayland_Drag) {}

wayland_activate :: proc(d: ^Wayland_Drag, token: string) -> bool {
	return false
}
