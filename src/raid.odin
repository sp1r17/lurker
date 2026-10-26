package app

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "vendor:curl"
import sdl "vendor:sdl3"

// Twitch's EventSub over a WebSocket. Twitch drops the session if nothing comes
// within the keepalive; it sends a keepalive message when there's nothing else.
EVENTSUB_URL :: "wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30"
EVENTSUB_KEEPALIVE :: 30 * time.Second
// How long past the keepalive a silent connection is given before reconnecting.
EVENTSUB_GRACE :: 10 * time.Second

// What the raid listener has to tell the main thread.
Raid_Event :: struct {
	// A new session to subscribe on (owned; "" for none).
	session: string,
	// The channel raided (owned; "" for none), and who by.
	to_login, to_name, from_name: string,
}

destroy_raid_event :: proc(e: Raid_Event) {
	delete(e.session)
	delete(e.to_login)
	delete(e.to_name)
	delete(e.from_name)
}

// Listens for the watched channel raiding another, to follow it there. A thread
// keeps an EventSub session open; the main thread subscribes it to the channel's
// raids (Raid_Subscribe_Job), since that needs the sign-in.
Raid_Listener :: struct {
	wake_event: u32,
	stop:       bool,
	mutex:      sync.Mutex,
	// Guarded by mutex.
	events:     [dynamic]Raid_Event,
	thread:     ^thread.Thread,
}

raid_listener_start :: proc(wake_event: u32) -> ^Raid_Listener {
	l := new(Raid_Listener)
	l.wake_event = wake_event
	l.thread = thread.create_and_start_with_poly_data(l, raid_thread, context)
	return l
}

raid_listener_stop :: proc(l: ^Raid_Listener) {
	if l == nil {
		return
	}
	sync.atomic_store(&l.stop, true)
	thread.join(l.thread)
	thread.destroy(l.thread)
	for e in l.events {
		destroy_raid_event(e)
	}
	delete(l.events)
	free(l)
}

// Moves what arrived since the last call onto the end of `into`.
raid_listener_take :: proc(l: ^Raid_Listener, into: ^[dynamic]Raid_Event) {
	sync.guard(&l.mutex)
	append(into, ..l.events[:])
	clear(&l.events)
}

@(private = "file")
raid_post :: proc(l: ^Raid_Listener, e: Raid_Event) {
	{
		sync.guard(&l.mutex)
		append(&l.events, e)
	}
	ev: sdl.Event
	ev.type = sdl.EventType(l.wake_event)
	_ = sdl.PushEvent(&ev)
}

@(private = "file")
raid_stopping :: proc(l: ^Raid_Listener) -> bool {
	return sync.atomic_load(&l.stop)
}

@(private = "file")
raid_thread :: proc(l: ^Raid_Listener) {
	for !raid_stopping(l) {
		raid_session(l)
		for waited: time.Duration; waited < CHAT_RECONNECT_DELAY && !raid_stopping(l); waited += 100 * time.Millisecond {
			time.sleep(100 * time.Millisecond)
		}
	}
}

// Connects and reads until the connection drops or goes quiet, Twitch asks for a
// reconnect, or the listener is stopped. Each connection is a new session, which
// the main thread subscribes again.
@(private = "file")
raid_session :: proc(l: ^Raid_Listener) {
	defer free_all(context.temp_allocator)
	h, multi, connected := ws_open(EVENTSUB_URL, &l.stop, "raids")
	defer ws_close(h, multi)
	if !connected {
		return
	}
	sock: curl.socket_t
	curl.easy_getinfo(h, .ACTIVESOCKET, &sock)

	payload := make([dynamic]u8)
	defer delete(payload)
	buf: [16 * 1024]u8
	heard := time.tick_now()
	for !raid_stopping(l) {
		for {
			n: c.size_t
			meta: ^curl.ws_frame
			rc := curl.ws_recv(h, &buf, len(buf), &n, &meta)
			if rc == .E_AGAIN {
				break
			}
			if rc != .E_OK {
				log.warnf("raids: read failed: %s", curl.easy_strerror(rc))
				return
			}
			if .CLOSE in meta.flags {
				return
			}
			heard = time.tick_now()
			if .TEXT not_in meta.flags && .CONT not_in meta.flags {
				continue
			}
			append(&payload, ..buf[:n])
			if meta.bytesleft == 0 && .CONT not_in meta.flags {
				e, kind := parse_eventsub(string(payload[:]))
				clear(&payload)
				free_all(context.temp_allocator)
				switch kind {
				case .Other:
				case .Event:
					raid_post(l, e)
				case .Reconnect:
					return
				}
			}
		}
		if time.tick_since(heard) > EVENTSUB_KEEPALIVE + EVENTSUB_GRACE {
			log.warn("raids: no keepalive; reconnecting")
			return
		}
		wait_readable(sock, CHAT_STOP_CHECK_MS)
	}
}

Eventsub_Kind :: enum {
	// A keepalive, or something not listened for.
	Other,
	// A new session, or a raid: in the Raid_Event.
	Event,
	// Twitch is moving the session, or revoked the subscription.
	Reconnect,
}

// One EventSub message. The event's strings are owned.
parse_eventsub :: proc(text: string) -> (e: Raid_Event, kind: Eventsub_Kind) {
	Message :: struct {
		metadata: struct {
			message_type: string,
		},
		payload:  struct {
			session:      struct {
				id: string,
			},
			subscription: struct {
				type: string,
			},
			event:        struct {
				from_broadcaster_user_name: string,
				to_broadcaster_user_login:  string,
				to_broadcaster_user_name:   string,
			},
		},
	}
	m: Message
	if json.unmarshal_string(text, &m, allocator = context.temp_allocator) != nil {
		return {}, .Other
	}
	p := m.payload
	switch m.metadata.message_type {
	case "session_welcome":
		if p.session.id != "" {
			return {session = strings.clone(p.session.id)}, .Event
		}
	case "notification":
		if p.subscription.type == "channel.raid" && valid_login(p.event.to_broadcaster_user_login) {
			e = {
				to_login  = strings.clone(p.event.to_broadcaster_user_login),
				to_name   = strings.clone(p.event.to_broadcaster_user_name),
				from_name = strings.clone(p.event.from_broadcaster_user_name),
			}
			return e, .Event
		}
	case "session_reconnect", "revocation":
		return {}, .Reconnect
	}
	return {}, .Other
}

// Listens for the watched channel's raids while it's live and following them is
// on; stops otherwise.
watch_listen_for_raids :: proc(app: ^App) {
	w := &app.watch
	want := app.signed_in && !app.layout.raids_off && w.channel != ""
	if want && w.raids == nil {
		w.raids = raid_listener_start(app.raid_event)
	} else if !want && w.raids != nil {
		raid_listener_stop(w.raids)
		w.raids = nil
	}
}

// Turns following raids on or off, and remembers it.
watch_toggle_raids :: proc(app: ^App) {
	app.watch.quality_menu = false
	app.layout.raids_off = !app.layout.raids_off
	layout_save(&app.layout)
	watch_listen_for_raids(app)
}

// On the main thread: subscribes each new session, and follows a raid to the
// channel raided.
raid_events_arrived :: proc(app: ^App) {
	w := &app.watch
	if app.screen != .Watch || w.raids == nil {
		return
	}
	events := make([dynamic]Raid_Event, context.temp_allocator)
	raid_listener_take(w.raids, &events)
	defer for e in events {
		destroy_raid_event(e)
	}
	for e in events {
		if e.session != "" {
			jobs_add(
				&app.assets.jobs,
				run_raid_subscribe_job,
				Raid_Subscribe_Job {
					client_id = strings.clone(app.client_id),
					auth = clone_auth(app.auth),
					login = strings.clone(w.channel),
					session = strings.clone(e.session),
				},
			)
		}
		// Not while a past broadcast plays: that's what's being watched.
		if e.to_login != "" && e.to_login != w.channel && !w.playing_vod {
			from := e.from_name if e.from_name != "" else w.channel
			from = strings.clone(from, context.temp_allocator)
			to := e.to_name if e.to_name != "" else e.to_login
			log.infof("following the raid from %s to %s", from, to)
			watch_start(app, e.to_login)
			pane_notice(app, app.watch.panes[0], fmt.tprintf("Followed the raid from %s.", from))
			// The rest were for the channel left.
			return
		}
	}
}

// Subscribes an EventSub session to a channel's raids.
Raid_Subscribe_Job :: struct {
	client_id: string,
	auth:      Auth,
	check:     Auth_Check,
	login:     string,
	session:   string,
	ok:        bool,
}

destroy_raid_subscribe_job :: proc(p: ^Raid_Subscribe_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.login)
	delete(p.session)
}

@(private = "file")
run_raid_subscribe_job :: proc(job: ^Job) {
	p := &job.payload.(Raid_Subscribe_Job)
	subscribe :: proc(p: ^Raid_Subscribe_Job) -> Twitch_Error {
		body := helix_get(p.client_id, p.auth.access_token, fmt.tprintf("/users?login=%s", p.login)) or_return
		user_id := parse_user_id(body) or_return
		return helix_post(p.client_id, p.auth.access_token, "/eventsub/subscriptions", raid_subscription(user_id, p.session))
	}
	p.check = .Valid
	err := subscribe(p)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		err = subscribe(p)
	}
	p.ok = err == .None
}

finish_raid_subscribe_job :: proc(app: ^App, p: ^Raid_Subscribe_Job) {
	apply_auth_check(app, p.check, p.auth)
	if !p.ok {
		log.warnf("can't listen for %s's raids", p.login)
	}
}

// The body that subscribes `session` to raids from the channel `user_id`.
raid_subscription :: proc(user_id, session: string) -> string {
	Subscription :: struct {
		type:      string,
		version:   string,
		condition: struct {
			from_broadcaster_user_id: string,
		},
		transport: struct {
			method:     string,
			session_id: string,
		},
	}
	s := Subscription {
		type    = "channel.raid",
		version = "1",
	}
	s.condition.from_broadcaster_user_id = user_id
	s.transport = {"websocket", session}
	data, _ := json.marshal(s, allocator = context.temp_allocator)
	return string(data)
}

// The user ID in a Helix /users response. Allocated with the temp allocator.
parse_user_id :: proc(body: []byte) -> (id: string, err: Twitch_Error) {
	Users :: struct {
		data: []struct {
			id: string,
		},
	}
	r: Users
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil || len(r.data) == 0 || r.data[0].id == "" {
		return "", .Bad_Json
	}
	return r.data[0].id, .None
}
