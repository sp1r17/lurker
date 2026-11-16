package app

// Not done yet on macOS: notifications are dropped. Notification Center needs a
// signed app bundle (UNUserNotificationCenter).

Notifications :: struct {
	// Never pushed, until clicks can arrive.
	click_event: u32,
}

notifications_init :: proc(app: ^App) {}

notifications_destroy :: proc(app: ^App) {}

show_notification :: proc(app: ^App, title, body, login: string, image := "") {}

notifications_take :: proc(n: ^Notifications, into: ^[dynamic]Notify_Click) {}
