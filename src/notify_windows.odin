package app

import win "core:sys/windows"
import sdl "vendor:sdl3"

// Notifications are a notification area icon's balloon, which Windows 10 and later
// show as a toast. The icon is added with the first one and stays until Lurker
// quits.

show_notification :: proc(app: ^App, title, body: string) {
	hwnd := win.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(app.window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
	if hwnd == nil {
		return
	}
	data := win.NOTIFYICONDATAW {
		cbSize = size_of(win.NOTIFYICONDATAW),
		hWnd   = hwnd,
		uID    = 1,
	}
	if !app.notify_icon {
		data.uFlags = win.NIF_ICON | win.NIF_TIP
		// lurker.rc's icon.
		data.hIcon = win.LoadIconW(win.HINSTANCE(win.GetModuleHandleW(nil)), cstring16(win.MAKEINTRESOURCEW(1)))
		copy_wide(data.szTip[:], APP_NAME)
		if !win.Shell_NotifyIconW(win.NIM_ADD, &data) {
			return
		}
		app.notify_icon = true
	}
	data.uFlags = win.NIF_INFO
	data.dwInfoFlags = NIIF_USER
	copy_wide(data.szInfoTitle[:], title)
	copy_wide(data.szInfo[:], body)
	win.Shell_NotifyIconW(win.NIM_MODIFY, &data)
}

// The balloon shows the notification area icon (NIIF_USER isn't in core:sys/windows).
@(private = "file")
NIIF_USER :: 0x4

// Removes the notification area icon, if a notification added it.
notifications_destroy :: proc(app: ^App) {
	if !app.notify_icon {
		return
	}
	hwnd := win.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(app.window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
	data := win.NOTIFYICONDATAW {
		cbSize = size_of(win.NOTIFYICONDATAW),
		hWnd   = hwnd,
		uID    = 1,
	}
	win.Shell_NotifyIconW(win.NIM_DELETE, &data)
	app.notify_icon = false
}

// Copies `s` into a fixed UTF-16 field, cut short to fit with its NUL.
@(private = "file")
copy_wide :: proc(dst: []u16, s: string) {
	wide := win.utf8_to_utf16(s, context.temp_allocator)
	n := min(len(wide), len(dst) - 1)
	copy(dst, wide[:n])
	dst[n] = 0
}
