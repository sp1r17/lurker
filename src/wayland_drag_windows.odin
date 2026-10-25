package app

import win "core:sys/windows"
import sdl "vendor:sdl3"

// Dragging the borderless window from the video on Windows, the same way as on
// Wayland (wayland_drag_linux.odin): the app sees the press and the mouse moving
// over the video, and only once a press becomes a drag does Windows move the
// window, as if its title bar had been pressed.
//
// SDL's hit test can't be used for the video here: Windows treats a draggable
// area as the title bar, so the app gets no mouse motion over it (the controls
// never show) and the mouse "leaves" the window when it moves onto it.
Wayland_Drag :: struct {
	hwnd: win.HWND,
}

wayland_drag_init :: proc(d: ^Wayland_Drag, window: ^sdl.Window) -> bool {
	d.hwnd = win.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
	return d.hwnd != nil
}

wayland_drag_destroy :: proc(d: ^Wayland_Drag) {}

wayland_drag_update :: proc(d: ^Wayland_Drag) {}

// Has Windows move the window with the pointer, for the left button that's held
// down now. Returns once the button is let go.
wayland_drag_start :: proc(d: ^Wayland_Drag) {
	// SDL holds the mouse capture while a button is down, which would keep the
	// press from Windows' move.
	win.ReleaseCapture()
	win.SendMessageW(d.hwnd, win.WM_NCLBUTTONDOWN, win.HTCAPTION, 0)
}

wayland_activate :: proc(d: ^Wayland_Drag, token: string) -> bool {
	return false
}
