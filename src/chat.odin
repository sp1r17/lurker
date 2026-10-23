package app

import "core:c"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "vendor:curl"
import sdl "vendor:sdl3"

CHAT_URL :: "wss://irc-ws.chat.twitch.tv:443"
CHAT_RECONNECT_DELAY :: 3 * time.Second
// How often the chat thread checks for messages to send, or whether to stop, while
// the socket is quiet.
CHAT_STOP_CHECK_MS :: 100

// Twitch chat for one channel, over IRC on a WebSocket: anonymous and read-only, or
// signed in and able to send. A thread owns the connection and hands finished
// messages to the main thread through `incoming`, pushing `wake_event` so the main
// loop picks them up.
Chat :: struct {
	// CHAT_URL unless a test sets another.
	url:        string,
	channel:    string,
	wake_event: u32,
	// Empty for anonymous, read-only chat.
	login:      string,
	token:      string,
	stop:       bool,
	mutex:      sync.Mutex,
	incoming:   [dynamic]Chat_Message,
	// Messages to send, from chat_send. Guarded by mutex.
	outgoing:   [dynamic]Outgoing,
	// The channel's user ID, from ROOMSTATE; "" until joined. Guarded by mutex.
	room_id:    string,
	// The tags of the last USERSTATE (our name, colour and badges in this channel),
	// for showing our own messages. Only the chat thread uses it.
	user_tags:  string,
	thread:     ^thread.Thread,
}

// Signs in as `login` if `token` isn't empty. curl.global_init must have been
// called. `channel` must outlive the chat.
chat_start :: proc(chat: ^Chat, channel: string, wake_event: u32, login := "", token := "") {
	chat.channel = channel
	chat.wake_event = wake_event
	chat.login = strings.clone(login)
	chat.token = strings.clone(token)
	chat.thread = thread.create_and_start_with_poly_data(chat, chat_thread, context)
}

// A message waiting to be sent. Owned.
Outgoing :: struct {
	text:     string,
	// For a reply: the tag that threads it, and the tags that show our copy as a
	// reply (see own_message). Empty otherwise.
	reply_tag:  string,
	reply_echo: string,
}

// What a message replies to: another message's ID, and its sender and text.
Chat_Reply :: struct {
	id, login, name, body: string,
}

// Queues a message to send, as a reply to `reply` if its ID isn't "". Line breaks
// become spaces: one could otherwise end the IRC line and smuggle in a command of
// its own.
chat_send :: proc(chat: ^Chat, text: string, reply := Chat_Reply{}) {
	line, _ := strings.replace_all(text, "\r", " ", context.temp_allocator)
	line, _ = strings.replace_all(line, "\n", " ", context.temp_allocator)
	out := Outgoing {
		text = strings.clone(line),
	}
	// Twitch's message IDs are UUIDs; anything else isn't sent, so it can't add tags.
	if reply.id != "" && strings.trim_left(reply.id, "0123456789abcdef-") == "" {
		out.reply_tag = fmt.aprintf("@reply-parent-msg-id=%s ", reply.id)
		out.reply_echo = fmt.aprintf(
			"reply-parent-display-name=%s;reply-parent-user-login=%s;reply-parent-msg-body=%s",
			escape_tag(reply.name),
			escape_tag(reply.login),
			escape_tag(reply.body),
		)
	}
	sync.guard(&chat.mutex)
	append(&chat.outgoing, out)
}

@(private = "file")
destroy_outgoing :: proc(out: Outgoing) {
	delete(out.text)
	delete(out.reply_tag)
	delete(out.reply_echo)
}

chat_stop :: proc(chat: ^Chat) {
	sync.atomic_store(&chat.stop, true)
	thread.join(chat.thread)
	thread.destroy(chat.thread)
	for m in chat.incoming {
		destroy_chat_message(m)
	}
	delete(chat.incoming)
	for out in chat.outgoing {
		destroy_outgoing(out)
	}
	delete(chat.outgoing)
	delete(chat.room_id)
	delete(chat.user_tags)
	delete(chat.login)
	delete(chat.token)
}

// The channel's user ID once the chat has joined, else "". Allocated with the temp
// allocator.
chat_room_id :: proc(chat: ^Chat) -> string {
	sync.guard(&chat.mutex)
	return strings.clone(chat.room_id, context.temp_allocator)
}

// Moves the messages that arrived since the last call onto the end of `into`.
chat_take :: proc(chat: ^Chat, into: ^[dynamic]Chat_Message) {
	sync.guard(&chat.mutex)
	append(into, ..chat.incoming[:])
	clear(&chat.incoming)
}

@(private = "file")
chat_post :: proc(chat: ^Chat, m: Chat_Message) {
	{
		sync.guard(&chat.mutex)
		append(&chat.incoming, m)
	}
	e: sdl.Event
	e.type = sdl.EventType(chat.wake_event)
	// Fails only when SDL's event queue is full; the next message pushes again.
	_ = sdl.PushEvent(&e)
}

@(private = "file")
stopping :: proc(chat: ^Chat) -> bool {
	return sync.atomic_load(&chat.stop)
}

@(private = "file")
chat_thread :: proc(chat: ^Chat) {
	for !stopping(chat) {
		chat_session(chat)
		if stopping(chat) {
			break
		}
		chat_post(chat, system_message("Disconnected, reconnecting..."))
		for waited: time.Duration; waited < CHAT_RECONNECT_DELAY && !stopping(chat); waited += 100 * time.Millisecond {
			time.sleep(100 * time.Millisecond)
		}
	}
}

// Connects, joins the channel and reads until the connection drops, Twitch asks for
// a reconnect, or the chat is stopped.
@(private = "file")
chat_session :: proc(chat: ^Chat) {
	defer free_all(context.temp_allocator)

	h := curl.easy_init()
	if h == nil {
		log.error("chat: curl init failed")
		return
	}
	defer curl.easy_cleanup(h)
	curl.easy_setopt(h, .URL, strings.clone_to_cstring(chat.url if chat.url != "" else CHAT_URL, context.temp_allocator))
	// 2 = connect, do the WebSocket upgrade, then hand the socket to ws_send/ws_recv.
	curl.easy_setopt(h, .CONNECT_ONLY, c.long(2))
	curl.easy_setopt(h, .CONNECTTIMEOUT, c.long(10))
	// Connecting can take until that timeout; checking for a stop while it does keeps
	// leaving a channel from waiting on it.
	curl.easy_setopt(h, .NOPROGRESS, c.long(0))
	curl.easy_setopt(h, .XFERINFODATA, chat)
	curl.easy_setopt(h, .XFERINFOFUNCTION, proc "c" (chat: rawptr, _, _, _, _: curl.off_t) -> c.int {
		return 1 if sync.atomic_load(&(^Chat)(chat).stop) else 0
	})
	if rc := curl.easy_perform(h); rc != .E_OK {
		if rc == .E_ABORTED_BY_CALLBACK {
			return
		}
		log.warnf("chat: can't connect: %s", curl.easy_strerror(rc))
		return
	}

	if !send_line(h, "CAP REQ :twitch.tv/tags twitch.tv/commands") {
		return
	}
	if chat.token != "" {
		if !send_line(h, fmt.tprintf("PASS oauth:%s", chat.token)) || !send_line(h, fmt.tprintf("NICK %s", chat.login)) {
			return
		}
	} else {
		// Anonymous read-only login: Twitch accepts any justinfan<number> nick.
		if !send_line(h, fmt.tprintf("NICK justinfan%d", 10000 + rand.int_max(90000))) {
			return
		}
	}
	if !send_line(h, fmt.tprintf("JOIN #%s", chat.channel)) {
		return
	}

	sock: curl.socket_t
	curl.easy_getinfo(h, .ACTIVESOCKET, &sock)

	// One WebSocket message can arrive over several ws_recv calls; this collects it.
	payload := make([dynamic]u8)
	defer delete(payload)
	buf: [16 * 1024]u8
	for !stopping(chat) {
		// TLS can hold decrypted data the socket no longer reports, so read until
		// curl runs dry before waiting on the socket.
		for {
			n: c.size_t
			meta: ^curl.ws_frame
			rc := curl.ws_recv(h, &buf, len(buf), &n, &meta)
			if rc == .E_AGAIN {
				break
			}
			if rc != .E_OK {
				log.warnf("chat: read failed: %s", curl.easy_strerror(rc))
				return
			}
			if .CLOSE in meta.flags {
				return
			}
			if .TEXT not_in meta.flags && .CONT not_in meta.flags {
				continue
			}
			append(&payload, ..buf[:n])
			if meta.bytesleft == 0 && .CONT not_in meta.flags {
				keep_going := handle_payload(chat, h, string(payload[:]))
				clear(&payload)
				free_all(context.temp_allocator)
				if !keep_going {
					return
				}
			}
		}

		if !send_outgoing(chat, h) {
			return
		}
		fds := [1]posix.pollfd{{fd = posix.FD(sock), events = {.IN}}}
		posix.poll(&fds[0], 1, CHAT_STOP_CHECK_MS)
	}
}

// Handles the IRC lines in one WebSocket message. Returns false to reconnect.
@(private = "file")
handle_payload :: proc(chat: ^Chat, h: ^curl.CURL, payload: string) -> bool {
	rest := payload
	for line in strings.split_lines_iterator(&rest) {
		msg, ok := parse_irc(strings.trim_right(line, "\r"))
		if !ok {
			continue
		}
		switch msg.command {
		case "PING":
			if !send_line(h, fmt.tprintf("PONG :%s", irc_trailing(msg))) {
				return false
			}
		case "RECONNECT":
			return false
		case "ROOMSTATE":
			// Sent once after joining, then again whenever a room setting changes.
			// Stored before the post below, so the main thread sees it when that wakes it.
			if id, has_id := irc_tag(msg, "room-id"); has_id {
				sync.guard(&chat.mutex)
				if chat.room_id == "" {
					chat.room_id = strings.clone(id)
				}
			}
			if _, has_slow := irc_tag(msg, "slow"); has_slow {
				chat_post(chat, system_message(fmt.tprintf("Joined #%s", chat.channel)))
			}
		case "PRIVMSG":
			chat_post(chat, privmsg_to_chat(msg))
		case "USERSTATE":
			delete(chat.user_tags)
			chat.user_tags = strings.clone(msg.tags)
		case "USERNOTICE":
			// Subs, gifts, raids: Twitch's own wording, then the user's message if any.
			if text, has_text := irc_tag(msg, "system-msg"); has_text {
				chat_post(chat, system_message(text))
			}
			if len(msg.params) > 1 {
				chat_post(chat, privmsg_to_chat(msg))
			}
		case "NOTICE":
			chat_post(chat, system_message(irc_trailing(msg)))
		case "CLEARCHAT", "CLEARMSG":
			if m, is_mod := moderation_message(msg); is_mod {
				chat_post(chat, m)
			}
		}
	}
	return true
}

// Sends the queued messages, showing each in chat: Twitch doesn't echo our own
// messages back. Returns false if the connection failed.
@(private = "file")
send_outgoing :: proc(chat: ^Chat, h: ^curl.CURL) -> bool {
	lines: [dynamic]Outgoing
	defer delete(lines)
	{
		sync.guard(&chat.mutex)
		lines, chat.outgoing = chat.outgoing, {}
	}
	defer for out in lines {
		destroy_outgoing(out)
	}
	if chat.token == "" {
		return true
	}
	for out in lines {
		if !send_line(h, fmt.tprintf("%sPRIVMSG #%s :%s", out.reply_tag, chat.channel, out.text)) {
			return false
		}
		tags := chat.user_tags
		if out.reply_echo != "" {
			tags = strings.join({chat.user_tags, out.reply_echo}, ";", context.temp_allocator) if tags != "" else out.reply_echo
		}
		chat_post(chat, own_message(chat.login, chat.channel, tags, out.text))
	}
	return true
}

// Our own message as Twitch would have sent it to others, styled from USERSTATE.
own_message :: proc(login, channel, user_tags, text: string) -> Chat_Message {
	msg := Irc_Message {
		tags    = user_tags,
		prefix  = fmt.tprintf("%s!%s@%s.tmi.twitch.tv", login, login, login),
		command = "PRIVMSG",
		params  = {fmt.tprintf("#%s", channel), text},
	}
	return privmsg_to_chat(msg)
}

@(private = "file")
send_line :: proc(h: ^curl.CURL, line: string) -> bool {
	data := transmute([]u8)line
	for len(data) > 0 {
		sent: c.size_t
		rc := curl.ws_send(h, raw_data(data), len(data), &sent, 0, curl.WS_TEXT)
		if rc != .E_OK && rc != .E_AGAIN {
			log.warnf("chat: send failed: %s", curl.easy_strerror(rc))
			return false
		}
		data = data[sent:]
		if rc == .E_AGAIN {
			time.sleep(10 * time.Millisecond)
		}
	}
	return true
}
