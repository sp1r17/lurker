package app

import "core:time"

// Chat matched to the stream (Layout.chat_sync): the live chat runs ahead of the
// picture by the stream's latency, so the watched channel's messages are held
// until the picture reaches the moment each was sent, using the latency to
// broadcaster (broadcaster_latency.odin). One's own messages, the app's notices
// and the history shown on joining aren't held. Until the latency is known, and
// for splits (whose streams aren't playing), nothing is.

// Whether `p`'s messages are being held back: it's the watched channel's chat,
// live, with chat matched to the stream.
@(private = "file")
chat_delayed :: proc(app: ^App, p: ^Chat_Pane) -> bool {
	w := &app.watch
	return app.layout.chat_sync && len(w.panes) > 0 && w.panes[0] == p && !w.playing_vod && w.status == .Playing
}

// How far behind the chat is held, in ms, if known.
@(private = "file")
chat_delay_ms :: proc(app: ^App) -> (ms: i64, ok: bool) {
	position := player_position(&app.player) or_return
	seconds := latency_seconds(app.watch.latency, position, time.now()) or_return
	return i64(max(seconds, 0) * 1000), true
}

// Sorts what just arrived in `p` into what shows now (left in `arrived`) and what
// waits (Chat_Pane.delayed).
chat_delay_hold :: proc(app: ^App, p: ^Chat_Pane, arrived: ^[dynamic]Chat_Message) {
	if !chat_delayed(app, p) {
		return
	}
	if _, known := chat_delay_ms(app); !known && len(p.delayed) == 0 {
		return
	}
	now := [dynamic]Chat_Message{}
	now.allocator = context.temp_allocator
	for m in arrived {
		// Behind something already waiting, so the order holds.
		if (m.id == "" || m.historical) && len(p.delayed) == 0 {
			append(&now, m)
		} else {
			append(&p.delayed, m)
		}
	}
	clear(arrived)
	append(arrived, ..now[:])
}

// Shows the held messages whose moment the picture has reached, or all of them
// once the chat is no longer held back. Returns ms until the next is due (-1 for
// none waiting), or 0 if it showed some, so the window draws them.
chat_delay_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	if app.screen != .Watch || len(w.panes) == 0 {
		return -1
	}
	p := w.panes[0]
	if len(p.delayed) == 0 {
		return -1
	}
	due := len(p.delayed)
	next := -1
	if chat_delayed(app, p) {
		if delay, known := chat_delay_ms(app); known {
			cutoff := time.time_to_unix_nano(time.now()) / 1e6 - delay
			due = 0
			for m in p.delayed {
				// The app's own lines go out with what's around them.
				if m.sent_ms > cutoff && m.id != "" && !m.historical {
					next = int(m.sent_ms - cutoff)
					break
				}
				due += 1
			}
		}
	}
	if due == 0 {
		return next
	}
	shown := make([dynamic]Chat_Message, context.temp_allocator)
	append(&shown, ..p.delayed[:due])
	remove_range(&p.delayed, 0, due)
	added, alerts := chat_view_add(&p.view, &app.assets, app.scale, pane_text_width(app, p), shown[:], app.auth.login if app.signed_in else "")
	if !pane_seen(app, p) {
		p.unread_mentions += added
	}
	mention_alert(app, alerts)
	return 0
}

chat_delay_destroy :: proc(p: ^Chat_Pane) {
	for m in p.delayed {
		destroy_chat_message(m)
	}
	delete(p.delayed)
}
