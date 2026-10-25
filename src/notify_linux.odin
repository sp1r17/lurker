package app

import "core:encoding/endian"
import "core:fmt"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import sdl "vendor:sdl3"

// Notifications go to the desktop's notification server over the session D-Bus
// (org.freedesktop.Notifications), spoken directly rather than through libdbus.
// A thread keeps the connection open to hear which notifications are clicked.

// How long to wait for the bus to answer while connecting.
DBUS_TIMEOUT_MS :: 2000
// Longer messages than this from the bus are taken for garbage.
DBUS_MAX_MESSAGE :: 1 << 20

Notifications :: struct {
	// Pushed when a click arrives, for notifications_take.
	click_event: u32,
	// The desktop file's name, for the icon and for grouping. Owned.
	app_id:      string,
	thread:      ^thread.Thread,
	mutex:       sync.Mutex,
	// Waiting for the thread to send, and clicks waiting for the main thread.
	// Owned.
	outgoing:    [dynamic]Notification,
	clicks:      [dynamic]Notify_Click,
	stop:        bool,
	// A pipe whose write end ([1]) wakes the thread.
	wake:        [2]posix.FD,
}

// A notification waiting to be sent, and the channel a click on it opens ("" for
// the one about many). Owned.
@(private = "file")
Notification :: struct {
	title: string,
	body:  string,
	login: string,
}

notifications_init :: proc(app: ^App) {
	n := &app.notifications
	n.click_event = sdl.RegisterEvents(1)
	n.app_id = strings.clone(app_icon_name())
	if posix.pipe(&n.wake) != .OK {
		log.warn("notification: can't make a pipe; no notifications")
		return
	}
	for fd in n.wake {
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	n.thread = thread.create_and_start_with_poly_data(n, notify_thread, context)
}

notifications_destroy :: proc(app: ^App) {
	n := &app.notifications
	if n.thread != nil {
		{
			sync.guard(&n.mutex)
			n.stop = true
		}
		notify_wake(n)
		thread.join(n.thread)
		thread.destroy(n.thread)
		posix.close(n.wake[0])
		posix.close(n.wake[1])
	}
	for m in n.outgoing {
		destroy_notification(m)
	}
	delete(n.outgoing)
	for c in n.clicks {
		destroy_notify_click(c)
	}
	delete(n.clicks)
	delete(n.app_id)
	n^ = {}
}

show_notification :: proc(app: ^App, title, body, login: string) {
	n := &app.notifications
	if n.thread == nil {
		return
	}
	sync.lock(&n.mutex)
	append(&n.outgoing, Notification{strings.clone(title), strings.clone(body), strings.clone(login)})
	sync.unlock(&n.mutex)
	notify_wake(n)
}

// Moves the clicks that arrived since the last call onto the end of `into`. The
// caller owns them.
notifications_take :: proc(n: ^Notifications, into: ^[dynamic]Notify_Click) {
	sync.guard(&n.mutex)
	append(into, ..n.clicks[:])
	clear(&n.clicks)
}

@(private = "file")
destroy_notification :: proc(m: Notification) {
	delete(m.title)
	delete(m.body)
	delete(m.login)
}

@(private = "file")
notify_wake :: proc(n: ^Notifications) {
	b := [1]byte{1}
	posix.write(n.wake[1], &b[0], 1)
}

// The desktop file's name: lurker, or in a Flatpak its ID. Allocated with the
// temp allocator.
app_icon_name :: proc() -> string {
	if id := os.get_env("FLATPAK_ID", context.temp_allocator); id != "" {
		return id
	}
	return APP_ID
}

// The notifier thread's connection, and what it knows of the notifications it
// sent. Notification IDs are the server's, so they're dropped with the connection.
Notify_Bus :: struct {
	sock:      posix.FD,
	connected: bool,
	serial:    u32,
	// What's arrived and isn't a whole message yet.
	buf:       [dynamic]byte,
	// By serial, Notify calls waiting for their ID; then by ID, the notifications
	// shown. Each with the channel a click opens. Owned values.
	pending:   map[u32]string,
	shown:     map[u32]string,
	// By notification ID, the token to raise the window with when it's clicked.
	// Owned values.
	tokens:    map[u32]string,
}

@(private = "file")
notify_thread :: proc(n: ^Notifications) {
	bus: Notify_Bus
	defer notify_bus_destroy(&bus)
	for {
		fds := [2]posix.pollfd{{fd = n.wake[0], events = {.IN}}, {fd = bus.sock if bus.connected else -1, events = {.IN}}}
		if posix.poll(&fds[0], 2, -1) < 0 && posix.errno() != .EINTR {
			log.warnf("notification: poll failed: %v", posix.errno())
			return
		}
		if .IN in fds[0].revents {
			drain: [64]byte
			posix.read(n.wake[0], &drain[0], len(drain))
		}
		outgoing: [dynamic]Notification
		{
			sync.guard(&n.mutex)
			if n.stop {
				return
			}
			outgoing, n.outgoing = n.outgoing, {}
		}
		for m in outgoing {
			notify_bus_send(&bus, n.app_id, m)
			destroy_notification(m)
		}
		delete(outgoing)
		if bus.connected && fds[1].revents & {.IN, .HUP, .ERR} != {} {
			notify_bus_read(&bus, n)
		}
		free_all(context.temp_allocator)
	}
}

// Sends a Notify call, connecting first if need be. A connection that's gone stale
// gets one more try.
@(private = "file")
notify_bus_send :: proc(bus: ^Notify_Bus, app_id: string, m: Notification) {
	for attempt in 0 ..< 2 {
		if !bus.connected && !notify_bus_connect(bus) {
			return
		}
		bus.serial += 1
		// The body takes a little markup, so its own <, > and & are escaped.
		msg := dbus_notify_message(bus.serial, app_id, m.title, notify_escape(m.body), "Watch" if m.login != "" else "Open")
		if dbus_send(bus.sock, msg) {
			bus.pending[bus.serial] = strings.clone(m.login)
			return
		}
		notify_bus_close(bus)
		if attempt == 1 {
			log.warn("notification: can't send to the session bus")
		}
	}
}

// Connects, then asks for the notification server's signals.
@(private = "file")
notify_bus_connect :: proc(bus: ^Notify_Bus) -> bool {
	sock, ok := dbus_connect()
	if !ok {
		return false
	}
	posix.fcntl(sock, .SETFD, posix.FD_CLOEXEC)
	rule := "type='signal',sender='org.freedesktop.Notifications',interface='org.freedesktop.Notifications'"
	body := Dbus_Writer{buf = make([dynamic]byte, context.temp_allocator)}
	dbus_string(&body, rule)
	add_match := dbus_method_call(2, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", body.buf[:])
	if !dbus_send(sock, add_match) {
		posix.close(sock)
		return false
	}
	bus.sock, bus.connected, bus.serial = sock, true, 2
	return true
}

// Reads what's arrived and handles each whole message. Clicks go to the main
// thread.
@(private = "file")
notify_bus_read :: proc(bus: ^Notify_Bus, n: ^Notifications) {
	chunk: [4096]byte
	got := posix.recv(bus.sock, &chunk[0], len(chunk), {})
	if got <= 0 {
		// The bus went away (or restarted); the next notification reconnects.
		notify_bus_close(bus)
		return
	}
	append(&bus.buf, ..chunk[:got])
	for len(bus.buf) >= 16 {
		size := dbus_message_size(bus.buf[:])
		if size > DBUS_MAX_MESSAGE {
			log.warn("notification: garbage from the session bus")
			notify_bus_close(bus)
			return
		}
		if len(bus.buf) < size {
			break
		}
		if click, ok := notify_bus_handle(bus, bus.buf[:size]).?; ok {
			{
				sync.guard(&n.mutex)
				append(&n.clicks, click)
			}
			e: sdl.Event
			e.type = sdl.EventType(n.click_event)
			// Fails only when SDL's event queue is full; the click is taken with
			// the next one.
			_ = sdl.PushEvent(&e)
		}
		remove_range(&bus.buf, 0, size)
	}
}

// Handles one message: a Notify call's reply, or a signal about a notification
// we sent. Returns a click, owned by the caller.
notify_bus_handle :: proc(bus: ^Notify_Bus, msg: []byte) -> Maybe(Notify_Click) {
	m, ok := dbus_parse(msg)
	if !ok {
		return nil
	}
	switch m.type {
	case DBUS_METHOD_RETURN, DBUS_ERROR:
		login, sent := bus.pending[m.reply_serial]
		if !sent {
			// Hello's or AddMatch's.
			return nil
		}
		delete_key(&bus.pending, m.reply_serial)
		if m.type == DBUS_ERROR || m.signature != "u" {
			log.warn("notification: no notification server took it")
			delete(login)
			return nil
		}
		id := dbus_read_u32(&m.body)
		if old, had := bus.shown[id]; had {
			delete(old)
		}
		bus.shown[id] = login
	case DBUS_SIGNAL:
		if m.interface != "org.freedesktop.Notifications" {
			return nil
		}
		switch m.member {
		case "ActivationToken":
			// Sent just before ActionInvoked, when the server has one.
			if m.signature != "us" {
				return nil
			}
			id := dbus_read_u32(&m.body)
			token := dbus_read_string(&m.body)
			if _, mine := bus.shown[id]; mine && m.body.ok {
				if old, had := bus.tokens[id]; had {
					delete(old)
				}
				bus.tokens[id] = strings.clone(token)
			}
		case "ActionInvoked":
			if m.signature != "us" {
				return nil
			}
			id := dbus_read_u32(&m.body)
			action := dbus_read_string(&m.body)
			login, mine := bus.shown[id]
			if !mine || !m.body.ok || action != "default" {
				return nil
			}
			_, token := delete_key(&bus.tokens, id)
			return Notify_Click{login = strings.clone(login), token = token}
		case "NotificationClosed":
			if m.signature != "uu" {
				return nil
			}
			id := dbus_read_u32(&m.body)
			_, login := delete_key(&bus.shown, id)
			delete(login)
			_, token := delete_key(&bus.tokens, id)
			delete(token)
		}
	}
	return nil
}

@(private = "file")
notify_bus_close :: proc(bus: ^Notify_Bus) {
	if bus.connected {
		posix.close(bus.sock)
	}
	bus.connected = false
	clear(&bus.buf)
	for _, v in bus.pending {
		delete(v)
	}
	for _, v in bus.shown {
		delete(v)
	}
	for _, v in bus.tokens {
		delete(v)
	}
	clear(&bus.pending)
	clear(&bus.shown)
	clear(&bus.tokens)
}

notify_bus_destroy :: proc(bus: ^Notify_Bus) {
	notify_bus_close(bus)
	delete(bus.buf)
	delete(bus.pending)
	delete(bus.shown)
	delete(bus.tokens)
}

// Connects and authenticates to the session bus, then says Hello (serial 1), as
// the bus requires before anything else.
@(private = "file")
dbus_connect :: proc() -> (sock: posix.FD, ok: bool) {
	addr := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	path, abstract, has_path := dbus_socket_path(addr)
	if !has_path {
		runtime_dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		if runtime_dir == "" {
			log.warn("notification: no session bus")
			return
		}
		path, abstract = fmt.tprintf("%s/bus", runtime_dir), false
	}
	sa: posix.sockaddr_un
	sa.sun_family = .UNIX
	offset := 1 if abstract else 0
	if offset + len(path) >= len(sa.sun_path) {
		return
	}
	copy(sa.sun_path[offset:], transmute([]c.char)path)
	sock = posix.socket(.UNIX, .STREAM)
	if sock < 0 {
		return
	}
	// An abstract address's length counts its leading NUL but no trailing one.
	addr_len := posix.socklen_t(size_of(sa.sun_family) + offset + len(path) + (0 if abstract else 1))
	if posix.connect(sock, (^posix.sockaddr)(&sa), addr_len) != .OK {
		log.warnf("notification: can't connect to the session bus at %s", path)
		posix.close(sock)
		return
	}
	defer if !ok {
		posix.close(sock)
	}

	// The EXTERNAL mechanism: the bus checks the socket's peer is this user.
	auth := fmt.tprintf("\x00AUTH EXTERNAL %s\r\n", dbus_hex(fmt.tprint(posix.getuid())))
	if !dbus_send(sock, transmute([]byte)auth) {
		return
	}
	line, line_ok := dbus_read_line(sock)
	if !line_ok || !strings.has_prefix(line, "OK ") {
		log.warnf("notification: the session bus refused us: %q", line)
		return
	}
	if !dbus_send(sock, transmute([]byte)string("BEGIN\r\n")) {
		return
	}
	hello := dbus_method_call(1, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", nil)
	return sock, dbus_send(sock, hello)
}

// The socket path from a bus address such as "unix:path=/run/user/1000/bus,guid=…"
// (the first unix: address with a path or abstract name).
dbus_socket_path :: proc(address: string) -> (path: string, abstract, ok: bool) {
	for entry in strings.split(address, ";", context.temp_allocator) {
		transport, _, params := strings.partition(entry, ":")
		if transport != "unix" {
			continue
		}
		for param in strings.split(params, ",", context.temp_allocator) {
			key, _, value := strings.partition(param, "=")
			switch key {
			case "path":
				return dbus_unescape(value), false, true
			case "abstract":
				return dbus_unescape(value), true, true
			}
		}
	}
	return "", false, false
}

// Undoes an address value's %XX escapes. Allocated with the temp allocator.
@(private = "file")
dbus_unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			hi, lo := hex_digit(s[i + 1]), hex_digit(s[i + 2])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&b, byte(hi * 16 + lo))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private = "file")
hex_digit :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

// Each byte as two lowercase hex digits. Allocated with the temp allocator.
@(private = "file")
dbus_hex :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]byte)s {
		fmt.sbprintf(&b, "%02x", c)
	}
	return strings.to_string(b)
}

// Escapes what the notification server would take as markup. Allocated with the
// temp allocator.
notify_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]byte)s {
		switch c {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
dbus_send :: proc(sock: posix.FD, data: []byte) -> bool {
	for sent := 0; sent < len(data); {
		n := posix.send(sock, raw_data(data[sent:]), c.size_t(len(data[sent:])), {.NOSIGNAL})
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

// Reads up to `len(buf)` bytes, waiting at most DBUS_TIMEOUT_MS.
@(private = "file")
dbus_recv :: proc(sock: posix.FD, buf: []byte) -> int {
	fds := [1]posix.pollfd{{fd = sock, events = {.IN}}}
	if posix.poll(&fds[0], 1, DBUS_TIMEOUT_MS) <= 0 {
		return 0
	}
	return max(int(posix.recv(sock, raw_data(buf), c.size_t(len(buf)), {})), 0)
}

// Reads the authentication's answer, a line ending "\r\n", a byte at a time so
// nothing after it is taken. Allocated with the temp allocator.
@(private = "file")
dbus_read_line :: proc(sock: posix.FD) -> (line: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	for strings.builder_len(b) < 512 {
		c: [1]byte
		if dbus_recv(sock, c[:]) != 1 {
			return strings.to_string(b), false
		}
		if c[0] == '\n' {
			return strings.trim_right(strings.to_string(b), "\r"), true
		}
		strings.write_byte(&b, c[0])
	}
	return strings.to_string(b), false
}

// A whole message's length, from its first 16 bytes.
dbus_message_size :: proc(header: []byte) -> int {
	order: endian.Byte_Order = .Little if header[0] == 'l' else .Big
	body, _ := endian.get_u32(header[4:8], order)
	fields, _ := endian.get_u32(header[12:16], order)
	return dbus_align(16 + int(fields), 8) + int(body)
}

DBUS_METHOD_CALL :: 1
DBUS_METHOD_RETURN :: 2
DBUS_ERROR :: 3
DBUS_SIGNAL :: 4

@(private = "file")
dbus_align :: proc(n, to: int) -> int {
	return (n + to - 1) / to * to
}

// Builds a message in the little-endian wire format. Offsets count from the
// start of the header, or of the body, both of which start 8-aligned.
Dbus_Writer :: struct {
	buf: [dynamic]byte,
}

@(private = "file")
dbus_pad :: proc(w: ^Dbus_Writer, to: int) {
	for len(w.buf) % to != 0 {
		append(&w.buf, 0)
	}
}

dbus_u32 :: proc(w: ^Dbus_Writer, v: u32) {
	dbus_pad(w, 4)
	b: [4]byte
	endian.put_u32(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

// A string or object path: its length, its bytes and a NUL.
dbus_string :: proc(w: ^Dbus_Writer, s: string) {
	dbus_u32(w, u32(len(s)))
	append(&w.buf, s)
	append(&w.buf, 0)
}

// A signature: a one-byte length, its bytes and a NUL.
@(private = "file")
dbus_signature :: proc(w: ^Dbus_Writer, s: string) {
	append(&w.buf, u8(len(s)))
	append(&w.buf, s)
	append(&w.buf, 0)
}

// Starts an array: its length is filled in by dbus_array_end. Elements aligned to
// 8 (structs and dict entries) start after padding the length doesn't count.
@(private = "file")
dbus_array_begin :: proc(w: ^Dbus_Writer, element_align: int) -> (length_at, start: int) {
	dbus_u32(w, 0)
	length_at = len(w.buf) - 4
	dbus_pad(w, element_align)
	return length_at, len(w.buf)
}

@(private = "file")
dbus_array_end :: proc(w: ^Dbus_Writer, length_at, start: int) {
	endian.put_u32(w.buf[length_at:], .Little, u32(len(w.buf) - start))
}

// A header field: its code and a variant holding a string-like value.
@(private = "file")
dbus_header_field :: proc(w: ^Dbus_Writer, code: u8, type: string, value: string) {
	dbus_pad(w, 8)
	append(&w.buf, code)
	dbus_signature(w, type)
	if type == "g" {
		dbus_signature(w, value)
	} else {
		dbus_string(w, value)
	}
}

// A method call message, its body already marshalled with `signature`.
// Allocated with the temp allocator.
dbus_method_call :: proc(serial: u32, destination, path, interface, member, signature: string, body: []byte) -> []byte {
	w := Dbus_Writer{buf = make([dynamic]byte, context.temp_allocator)}
	append(&w.buf, 'l', DBUS_METHOD_CALL, 0, 1)
	dbus_u32(&w, u32(len(body)))
	dbus_u32(&w, serial)
	length_at, start := dbus_array_begin(&w, 8)
	dbus_header_field(&w, 1, "o", path)
	dbus_header_field(&w, 2, "s", interface)
	dbus_header_field(&w, 3, "s", member)
	dbus_header_field(&w, 6, "s", destination)
	if signature != "" {
		dbus_header_field(&w, 8, "g", signature)
	}
	dbus_array_end(&w, length_at, start)
	dbus_pad(&w, 8)
	append(&w.buf, ..body)
	return w.buf[:]
}

// org.freedesktop.Notifications.Notify, showing `title` and `body` (already
// escaped) with the app's icon. A click on it invokes its default action, named
// `action`. Allocated with the temp allocator.
dbus_notify_message :: proc(serial: u32, app_id, title, body, action: string) -> []byte {
	w := Dbus_Writer{buf = make([dynamic]byte, context.temp_allocator)}
	dbus_string(&w, APP_NAME) // app_name
	dbus_u32(&w, 0) // replaces_id
	dbus_string(&w, app_id) // app_icon
	dbus_string(&w, title) // summary
	dbus_string(&w, body)
	actions_at, actions_start := dbus_array_begin(&w, 4)
	dbus_string(&w, "default")
	dbus_string(&w, action)
	dbus_array_end(&w, actions_at, actions_start)
	hints_at, hints_start := dbus_array_begin(&w, 8)
	// Which desktop file it's from, for the app's name and settings.
	dbus_pad(&w, 8)
	dbus_string(&w, "desktop-entry")
	dbus_signature(&w, "s")
	dbus_string(&w, app_id)
	dbus_array_end(&w, hints_at, hints_start)
	dbus_u32(&w, transmute(u32)i32(-1)) // expire_timeout: the server's default
	return dbus_method_call(
		serial,
		"org.freedesktop.Notifications",
		"/org/freedesktop/Notifications",
		"org.freedesktop.Notifications",
		"Notify",
		"susssasa{sv}i",
		w.buf[:],
	)
}

// A received message's header fields, and its body to read.
Dbus_Message :: struct {
	type:         u8,
	reply_serial: u32,
	interface:    string,
	member:       string,
	signature:    string,
	body:         Dbus_Reader,
}

// Reads values from a whole message, in its byte order. Offsets count from the
// message's start, like the writer's. `ok` goes false on running off the end.
Dbus_Reader :: struct {
	data:  []byte,
	pos:   int,
	order: endian.Byte_Order,
	ok:    bool,
}

// Reads a whole message's header fields; its strings point into `msg`.
dbus_parse :: proc(msg: []byte) -> (m: Dbus_Message, ok: bool) {
	r := Dbus_Reader {
		data  = msg,
		pos   = 12,
		order = .Little if msg[0] == 'l' else .Big,
		ok    = true,
	}
	m.type = msg[1]
	end := 16 + int(dbus_read_u32(&r))
	for r.ok {
		r.pos = dbus_align(r.pos, 8)
		if r.pos >= end {
			break
		}
		code := msg[r.pos]
		r.pos += 1
		switch dbus_read_signature(&r) {
		case "s", "o":
			value := dbus_read_string(&r)
			switch code {
			case 2:
				m.interface = value
			case 3:
				m.member = value
			}
		case "u":
			value := dbus_read_u32(&r)
			if code == 5 {
				m.reply_serial = value
			}
		case "g":
			value := dbus_read_signature(&r)
			if code == 8 {
				m.signature = value
			}
		case:
			// No header field has any other type.
			return m, false
		}
	}
	m.body = {
		data  = msg,
		pos   = dbus_align(end, 8),
		order = r.order,
		ok    = true,
	}
	return m, r.ok
}

dbus_read_u32 :: proc(r: ^Dbus_Reader) -> u32 {
	r.pos = dbus_align(r.pos, 4)
	if r.pos + 4 > len(r.data) {
		r.ok = false
		return 0
	}
	v, _ := endian.get_u32(r.data[r.pos:r.pos + 4], r.order)
	r.pos += 4
	return v
}

// A string or object path.
dbus_read_string :: proc(r: ^Dbus_Reader) -> string {
	n := int(dbus_read_u32(r))
	return dbus_read_bytes(r, n)
}

@(private = "file")
dbus_read_signature :: proc(r: ^Dbus_Reader) -> string {
	if r.pos >= len(r.data) {
		r.ok = false
		return ""
	}
	n := int(r.data[r.pos])
	r.pos += 1
	return dbus_read_bytes(r, n)
}

// `n` bytes and the NUL after them.
@(private = "file")
dbus_read_bytes :: proc(r: ^Dbus_Reader, n: int) -> string {
	if !r.ok || r.pos + n + 1 > len(r.data) {
		r.ok = false
		return ""
	}
	s := string(r.data[r.pos:r.pos + n])
	r.pos += n + 1
	return s
}
