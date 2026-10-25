package app

import "core:strings"
import win "core:sys/windows"
import sdl "vendor:sdl3"

// Notifications are a notification area icon's balloon, which Windows 10 and later
// show as a toast. The icon is added with the first one and stays until Lurker
// quits. A click on the balloon comes to the window as the icon's callback message,
// which SDL's message hook sees.

Notifications :: struct {
	// Pushed when the balloon is clicked, for notifications_take.
	click_event: u32,
	// Whether the notification area icon has been added.
	icon:        bool,
	// The channel the last balloon is about ("" for many channels). Owned.
	login:       string,
	clicked:     bool,
}

// The icon's callback message, and the click it carries in lParam.
@(private = "file")
NOTIFY_MESSAGE :: win.WM_APP + 1
@(private = "file")
NIN_BALLOONUSERCLICK :: win.WM_USER + 5

notifications_init :: proc(app: ^App) {
	app.notifications.click_event = sdl.RegisterEvents(1)
	sdl.SetWindowsMessageHook(notify_message_hook, &app.notifications)
}

// Runs on the main thread, in SDL's event pump, for every message.
@(private = "file")
notify_message_hook :: proc "c" (userdata: rawptr, msg: ^win.MSG) -> bool {
	if msg.message == NOTIFY_MESSAGE && u32(msg.lParam) & 0xffff == NIN_BALLOONUSERCLICK {
		n := (^Notifications)(userdata)
		n.clicked = true
		e: sdl.Event
		e.type = sdl.EventType(n.click_event)
		_ = sdl.PushEvent(&e)
	}
	return true
}

show_notification :: proc(app: ^App, title, body, login: string) {
	n := &app.notifications
	hwnd := win.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(app.window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
	if hwnd == nil {
		return
	}
	data := win.NOTIFYICONDATAW {
		cbSize = size_of(win.NOTIFYICONDATAW),
		hWnd   = hwnd,
		uID    = 1,
	}
	if !n.icon {
		data.uFlags = win.NIF_ICON | win.NIF_TIP | win.NIF_MESSAGE
		data.uCallbackMessage = NOTIFY_MESSAGE
		// lurker.rc's icon.
		data.hIcon = win.LoadIconW(win.HINSTANCE(win.GetModuleHandleW(nil)), cstring16(win.MAKEINTRESOURCEW(1)))
		copy_wide(data.szTip[:], APP_NAME)
		if !win.Shell_NotifyIconW(win.NIM_ADD, &data) {
			return
		}
		n.icon = true
	}
	data.uFlags = win.NIF_INFO
	data.dwInfoFlags = NIIF_USER
	copy_wide(data.szInfoTitle[:], title)
	copy_wide(data.szInfo[:], body)
	if win.Shell_NotifyIconW(win.NIM_MODIFY, &data) {
		// A new balloon replaces the last, so a click is on this one.
		delete(n.login)
		n.login = strings.clone(login)
	}
}

// The balloon shows the notification area icon (NIIF_USER isn't in core:sys/windows).
@(private = "file")
NIIF_USER :: 0x4

// The click since the last call, if any; the caller owns it.
notifications_take :: proc(n: ^Notifications, into: ^[dynamic]Notify_Click) {
	if n.clicked {
		append(into, Notify_Click{login = strings.clone(n.login)})
		n.clicked = false
	}
}

// Removes the notification area icon, if a notification added it.
notifications_destroy :: proc(app: ^App) {
	n := &app.notifications
	sdl.SetWindowsMessageHook(nil, nil)
	delete(n.login)
	if !n.icon {
		n^ = {}
		return
	}
	hwnd := win.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(app.window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
	data := win.NOTIFYICONDATAW {
		cbSize = size_of(win.NOTIFYICONDATAW),
		hWnd   = hwnd,
		uID    = 1,
	}
	win.Shell_NotifyIconW(win.NIM_DELETE, &data)
	n^ = {}
}

// Copies `s` into a fixed UTF-16 field, cut short to fit with its NUL.
@(private = "file")
copy_wide :: proc(dst: []u16, s: string) {
	wide := win.utf8_to_utf16(s, context.temp_allocator)
	n := min(len(wide), len(dst) - 1)
	copy(dst, wide[:n])
	dst[n] = 0
}
