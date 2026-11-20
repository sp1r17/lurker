#+build !linux
package app

import sdl "vendor:sdl3"

// Quitting when the display goes is for Wayland and X11 (display_linux.odin).

display_watch :: proc(window: ^sdl.Window) {}
