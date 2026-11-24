package app

import "core:fmt"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

// Followed channels are checked this often off the Following tab (which refreshes
// every BROWSE_REFRESH_MS anyway), to notice them going live.
LIVE_POLL_MS :: 2 * 60_000
// A channel back within this long of dropping out of the list (a crashed or
// restarted stream) doesn't count as going live again.
LIVE_GRACE_MS :: 10 * 60_000
// More channels than this going live at once share one notification.
LIVE_NOTIFY_MAX :: 3

// Which followed channels were live when, to tell which have just gone live.
Live_Notifier :: struct {
	// Whether a list has arrived yet: the channels already live when Lurker starts
	// (or signs in) aren't announced.
	seeded:    bool,
	// When the last list arrived.
	last_poll: int,
	// When each channel (by user ID; owned keys) was last in the list. Channels
	// gone longer than LIVE_GRACE_MS are dropped.
	last_seen: map[string]int,
	// Each channel's title and category in the last list (by user ID; all
	// owned), to tell when they change (live_notifier_info_changes).
	info:      map[string]Seen_Info,
}

Seen_Info :: struct {
	title, category: string,
}

// A channel whose title or category changed: its index in the list.
Info_Change :: struct {
	index:    int,
	title:    bool,
	category: bool,
}

live_notifier_clear :: proc(n: ^Live_Notifier) {
	for id in n.last_seen {
		delete(id)
	}
	clear(&n.last_seen)
	for id, seen in n.info {
		delete(id)
		delete(seen.title)
		delete(seen.category)
	}
	clear(&n.info)
	n.seeded = false
	n.last_poll = 0
}

live_notifier_destroy :: proc(n: ^Live_Notifier) {
	live_notifier_clear(n)
	delete(n.last_seen)
	delete(n.info)
}

// Takes a new list of the followed channels that are live, and returns those
// whose title or category changed since the last list. Only channels in both
// count: one going live is announced as that. Allocated with the temp
// allocator.
live_notifier_info_changes :: proc(n: ^Live_Notifier, streams: []Stream) -> []Info_Change {
	changes := make([dynamic]Info_Change, context.temp_allocator)
	now := make(map[string]struct{}, len(streams), context.temp_allocator)
	for s, i in streams {
		now[s.user_id] = {}
		if seen, ok := &n.info[s.user_id]; ok {
			c := Info_Change{index = i, title = seen.title != s.title, category = seen.category != s.game_name}
			if c.title || c.category {
				append(&changes, c)
				delete(seen.title)
				delete(seen.category)
				seen^ = {strings.clone(s.title), strings.clone(s.game_name)}
			}
		} else {
			n.info[strings.clone(s.user_id)] = {strings.clone(s.title), strings.clone(s.game_name)}
		}
	}
	gone := make([dynamic]string, context.temp_allocator)
	for id in n.info {
		if id not_in now {
			append(&gone, id)
		}
	}
	for id in gone {
		key, seen := delete_key(&n.info, id)
		delete(key)
		delete(seen.title)
		delete(seen.category)
	}
	return changes[:]
}

// A channel's notification for a new title or category. Allocated with the temp
// allocator.
info_change_notification :: proc(s: Stream, c: Info_Change) -> (title, body: string) {
	switch {
	case c.title && c.category:
		return fmt.tprintf("%s changed title and category", s.user_name), fmt.tprintf("%s\n%s", s.title, s.game_name)
	case c.category:
		return fmt.tprintf("%s is now in %s", s.user_name, s.game_name), s.title
	}
	return fmt.tprintf("%s changed the title", s.user_name), s.title
}

// Takes a new list of the followed channels that are live, and returns the
// indices of those that have just gone live. Allocated with the temp allocator.
live_notifier_update :: proc(n: ^Live_Notifier, streams: []Stream, now: int) -> []int {
	went_live := make([dynamic]int, context.temp_allocator)
	for s, i in streams {
		if seen, ok := n.last_seen[s.user_id]; ok {
			// In the last list, or out of it only briefly.
			if n.last_poll - seen > LIVE_GRACE_MS {
				append(&went_live, i)
			}
			n.last_seen[s.user_id] = now
		} else {
			if n.seeded {
				append(&went_live, i)
			}
			n.last_seen[strings.clone(s.user_id)] = now
		}
	}
	stale := make([dynamic]string, context.temp_allocator)
	for id, seen in n.last_seen {
		if now - seen > LIVE_GRACE_MS {
			append(&stale, id)
		}
	}
	for id in stale {
		delete_key(&n.last_seen, id)
		delete(id)
	}
	n.seeded = true
	n.last_poll = now
	return went_live[:]
}

// Marks a channel just followed while live as seen, so its turning up in the
// next list isn't taken for it going live.
live_notifier_seen :: proc(n: ^Live_Notifier, user_id: string, now: int) {
	if !n.seeded {
		return
	}
	if _, ok := n.last_seen[user_id]; ok {
		n.last_seen[user_id] = now
	} else {
		n.last_seen[strings.clone(user_id)] = now
	}
}

// Keeps the followed channels' list fresh while it's not shown, for
// notifications. Returns ms until it's next due, for the main loop's wait.
// No live notifications on macOS: Notification Center needs an app signed with
// an Apple Developer ID. Their settings and menu items are hidden there.
NOTIFICATIONS_SUPPORTED :: ODIN_OS != .Darwin

// Whether to watch for channels going live and announce them.
notifications_on :: proc(app: ^App) -> bool {
	return NOTIFICATIONS_SUPPORTED && !app.layout.notifications_off
}

live_poll_tick :: proc(app: ^App) -> (wait_ms: int) {
	l := &app.browse.following
	if !app.signed_in || !notifications_on(app) || l.state == .Loading {
		return -1
	}
	due := l.last_refresh + LIVE_POLL_MS
	now := app.assets.now_ms
	if l.state == .Empty || now >= due {
		stream_list_refresh(app, .Following)
		return -1
	}
	return due - now
}

// On the main thread, with each new list of the followed channels that are live:
// announces the ones that have just gone live, except one being watched.
live_notify :: proc(app: ^App, streams: []Stream) {
	if !notifications_on(app) {
		return
	}
	went_live := live_notifier_update(&app.live, streams, app.assets.now_ms)
	changed := live_notifier_info_changes(&app.live, streams)
	if app.layout.notify_changes {
		info_notify(app, streams, changed)
	}
	announce := make([dynamic]Stream, context.temp_allocator)
	for i in went_live {
		s := streams[i]
		if app.screen == .Watch && s.user_login == app.watch.channel {
			continue
		}
		if !notify_wanted(&app.layout, s.user_login) {
			continue
		}
		append(&announce, s)
	}
	if len(announce) > LIVE_NOTIFY_MAX {
		title, body := live_notification_summary(announce[:])
		show_notification(app, title, body, "")
		return
	}
	if len(announce) == 0 {
		return
	}
	// Each shows once its channel's avatar is found.
	p := Notify_Job {
		client_id = strings.clone(app.client_id),
		auth      = clone_auth(app.auth),
	}
	for s in announce {
		title, body := live_notification(s)
		append(&p.notifications, Live_Notification{title = strings.clone(title), body = strings.clone(body), login = strings.clone(s.user_login)})
	}
	jobs_add(&app.assets.jobs, run_notify_job, p)
}

// Announces the channels in `changed` with a new title or category, except one
// being watched and those not wanted; many at once share one notification.
@(private = "file")
info_notify :: proc(app: ^App, streams: []Stream, changed: []Info_Change) {
	p := Notify_Job {
		client_id = strings.clone(app.client_id),
		auth      = clone_auth(app.auth),
	}
	for c in changed {
		s := streams[c.index]
		if (app.screen == .Watch && s.user_login == app.watch.channel) || !notify_wanted(&app.layout, s.user_login) {
			continue
		}
		title, body := info_change_notification(s, c)
		append(&p.notifications, Live_Notification{title = strings.clone(title), body = strings.clone(body), login = strings.clone(s.user_login)})
	}
	switch {
	case len(p.notifications) == 0:
		destroy_notify_job(&p)
	case len(p.notifications) > LIVE_NOTIFY_MAX:
		show_notification(app, fmt.tprintf("%d channels you follow changed title or category", len(p.notifications)), "", "")
		destroy_notify_job(&p)
	case:
		jobs_add(&app.assets.jobs, run_notify_job, p)
	}
}

// One channel's notification: its text, the channel a click opens, and its
// avatar's file ("" for none). Owned.
Live_Notification :: struct {
	title: string,
	body:  string,
	login: string,
	image: string,
}

// Finds the avatars of channels that just went live, for their notifications.
Notify_Job :: struct {
	client_id:     string,
	// A copy; the job may refresh it.
	auth:          Auth,
	check:         Auth_Check,
	// Owned. The worker fills in each one's image.
	notifications: [dynamic]Live_Notification,
}

destroy_notify_job :: proc(p: ^Notify_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	for n in p.notifications {
		delete(n.title)
		delete(n.body)
		delete(n.login)
		delete(n.image)
	}
	delete(p.notifications)
}

@(private = "file")
run_notify_job :: proc(job: ^Job) {
	p := &job.payload.(Notify_Job)
	logins := make([]string, len(p.notifications), context.temp_allocator)
	for n, i in p.notifications {
		logins[i] = n.login
	}
	p.check = .Valid
	channels, err := get_channel_status(p.client_id, p.auth.access_token, logins)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		channels, err = get_channel_status(p.client_id, p.auth.access_token, logins)
	}
	if err != .None {
		return
	}
	for &n in p.notifications {
		for c in channels {
			if c.login != n.login || c.avatar_url == "" {
				continue
			}
			if path, ok := cached_file(c.avatar_url); ok {
				n.image = strings.clone(path)
			}
			break
		}
	}
}

// On the main thread: shows the notifications, with or without avatars, unless
// notifications were turned off (or the user signed out) meanwhile.
finish_notify_job :: proc(app: ^App, p: ^Notify_Job) {
	apply_auth_check(app, p.check, p.auth)
	if !app.signed_in || !notifications_on(app) {
		return
	}
	for n in p.notifications {
		show_notification(app, n.title, n.body, n.login, n.image)
	}
}

// The browse header's switch. Turned back on, the next list is a new start, so
// channels that went live in the meantime aren't announced late.
live_notifications_toggle :: proc(app: ^App) {
	app.layout.notifications_off = !app.layout.notifications_off
	live_notifier_clear(&app.live)
	layout_save(&app.layout)
}

// "<name> is live", then the stream's title and category. Allocated with the temp
// allocator.
live_notification :: proc(s: Stream) -> (title, body: string) {
	title = fmt.tprintf("%s is live", s.user_name)
	switch {
	case s.title != "" && s.game_name != "":
		body = fmt.tprintf("%s\n%s", s.title, s.game_name)
	case s.title != "":
		body = s.title
	case:
		body = s.game_name
	}
	return
}

// For many channels at once: how many, then their names. Allocated with the temp
// allocator.
live_notification_summary :: proc(streams: []Stream) -> (title, body: string) {
	title = fmt.tprintf("%d channels you follow are live", len(streams))
	b := strings.builder_make(context.temp_allocator)
	for s, i in streams {
		switch {
		case i == 0:
		case i == len(streams) - 1:
			strings.write_string(&b, " and ")
		case:
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, s.user_name)
	}
	return title, strings.to_string(b)
}

// A click on a notification: the channel it's about, or "" for the one about many
// channels. Owned.
Notify_Click :: struct {
	login: string,
	// From the notification server, to raise the window with on Wayland; "" if
	// it gave none.
	token: string,
}

destroy_notify_click :: proc(c: Notify_Click) {
	delete(c.login)
	delete(c.token)
}

// On the main thread, when notifications have been clicked.
notifications_clicked :: proc(app: ^App) {
	clicks := make([dynamic]Notify_Click, context.temp_allocator)
	notifications_take(&app.notifications, &clicks)
	for c in clicks {
		notification_clicked(app, c)
		destroy_notify_click(c)
	}
}

// Brings the window up and watches the channel, or for the notification about
// many, shows the Following tab.
@(private = "file")
notification_clicked :: proc(app: ^App, c: Notify_Click) {
	window_activate(app, c.token)
	if c.login == "" {
		if app.screen == .Watch {
			watch_stop(app)
		}
		browse_set_view(app, .Following)
		return
	}
	if app.screen == .Watch && app.watch.channel == c.login {
		return
	}
	for &s in app.browse.following.streams {
		if s.user_login == c.login {
			watch_start(app, s.user_login, info = &s)
			return
		}
	}
	watch_start(app, c.login)
}

// Restores the window if it's minimized and asks to bring it to the front. On
// Wayland that takes an activation token; without one the compositor may only
// mark the window as wanting attention.
@(private = "file")
window_activate :: proc(app: ^App, token: string) {
	if .MINIMIZED in sdl.GetWindowFlags(app.window) {
		sdl.RestoreWindow(app.window)
	}
	if token != "" && wayland_activate(&app.wayland_drag, token) {
		return
	}
	sdl.RaiseWindow(app.window)
}

// Whether `login` going live is announced: in all followed channels but those
// muted, or only those chosen (Layout.notify_only).
notify_wanted :: proc(l: ^Layout, login: string) -> bool {
	if l.notify_only {
		return slice.contains(l.notify_chosen[:], login)
	}
	return !slice.contains(l.notify_muted[:], login)
}

// Mutes or unmutes `login`'s live notifications, or (only chosen channels
// notifying) chooses it or not, and saves.
notify_toggle :: proc(app: ^App, login: string) {
	l := &app.layout
	list := &l.notify_chosen if l.notify_only else &l.notify_muted
	if !rule_remove(list, login) {
		rule_add(list, login)
	}
	layout_save(l)
}
