package app

// No notifications on macOS (see NOTIFICATIONS_SUPPORTED): Notification Center
// needs an app signed with an Apple Developer ID.

Notifications :: struct {
	// Never pushed.
	click_event: u32,
}

notifications_init :: proc(app: ^App) {}

notifications_destroy :: proc(app: ^App) {}

show_notification :: proc(app: ^App, title, body, login: string, image := "") {}

notifications_take :: proc(n: ^Notifications, into: ^[dynamic]Notify_Click) {}
