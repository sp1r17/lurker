package app

import "core:fmt"
import "core:strings"

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
}

live_notifier_clear :: proc(n: ^Live_Notifier) {
	for id in n.last_seen {
		delete(id)
	}
	clear(&n.last_seen)
	n.seeded = false
	n.last_poll = 0
}

live_notifier_destroy :: proc(n: ^Live_Notifier) {
	live_notifier_clear(n)
	delete(n.last_seen)
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
live_poll_tick :: proc(app: ^App) -> (wait_ms: int) {
	l := &app.browse.following
	if !app.signed_in || l.state == .Loading {
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
	went_live := live_notifier_update(&app.live, streams, app.assets.now_ms)
	announce := make([dynamic]Stream, context.temp_allocator)
	for i in went_live {
		s := streams[i]
		if app.screen == .Watch && s.user_login == app.watch.channel {
			continue
		}
		append(&announce, s)
	}
	if len(announce) > LIVE_NOTIFY_MAX {
		title, body := live_notification_summary(announce[:])
		show_notification(app, title, body)
		return
	}
	for s in announce {
		title, body := live_notification(s)
		show_notification(app, title, body)
	}
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

// Sends one notification (on Linux; Windows shows them on the main thread).
Notify_Job :: struct {
	// The desktop file's name, for the icon and for grouping.
	app_id: string,
	title:  string,
	body:   string,
}

destroy_notify_job :: proc(p: ^Notify_Job) {
	delete(p.app_id)
	delete(p.title)
	delete(p.body)
}
