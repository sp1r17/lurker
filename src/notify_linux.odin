package app

import "core:encoding/endian"
import "core:fmt"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Notifications go to the desktop's notification server over the session D-Bus
// (org.freedesktop.Notifications), spoken directly rather than through libdbus.

// How long to wait for the bus to answer each step.
DBUS_TIMEOUT_MS :: 2000

show_notification :: proc(app: ^App, title, body: string) {
	jobs_add(
		&app.assets.jobs,
		run_notify_job,
		Notify_Job {
			app_id = strings.clone(app_icon_name()),
			title = strings.clone(title),
			body = strings.clone(body),
		},
	)
}

// The desktop file's name: lurker, or in a Flatpak its ID. Allocated with the
// temp allocator.
app_icon_name :: proc() -> string {
	if id := os.get_env("FLATPAK_ID", context.temp_allocator); id != "" {
		return id
	}
	return APP_ID
}

@(private = "file")
run_notify_job :: proc(job: ^Job) {
	p := &job.payload.(Notify_Job)
	send_notification(p.app_id, p.title, p.body)
}

// Sends a notification and waits for the server to take it.
send_notification :: proc(app_id, title, body: string) -> bool {
	sock, ok := dbus_connect()
	if !ok {
		return false
	}
	defer posix.close(sock)
	// The body takes a little markup, so its own <, > and & are escaped.
	msg := dbus_notify_message(2, app_id, title, notify_escape(body))
	if !dbus_send(sock, msg) {
		log.warn("notification: can't send to the session bus")
		return false
	}
	// Leaving before the reply could drop the call: the second reply is Notify's
	// (the first is Hello's).
	if !dbus_await_replies(sock, 2) {
		log.warn("notification: no notification server took it")
		return false
	}
	return true
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

// Reads messages until `count` method returns or errors have arrived, skipping
// signals such as NameAcquired. False if the last is an error.
@(private = "file")
dbus_await_replies :: proc(sock: posix.FD, count: int) -> bool {
	buf := make([dynamic]byte, context.temp_allocator)
	replies := 0
	for replies < count {
		// A whole message: its fixed header, its header fields padded to 8, its body.
		for len(buf) < 16 || len(buf) < dbus_message_size(buf[:]) {
			chunk: [4096]byte
			n := dbus_recv(sock, chunk[:])
			if n == 0 {
				return false
			}
			append(&buf, ..chunk[:n])
		}
		size := dbus_message_size(buf[:])
		if buf[1] == DBUS_METHOD_RETURN || buf[1] == DBUS_ERROR {
			replies += 1
			if replies == count && buf[1] == DBUS_ERROR {
				return false
			}
		}
		remove_range(&buf, 0, size)
	}
	return true
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

@(private = "file")
dbus_align :: proc(n, to: int) -> int {
	return (n + to - 1) / to * to
}

// Builds a message in the little-endian wire format. Offsets count from the
// start of the header, or of the body, both of which start 8-aligned.
@(private = "file")
Dbus_Writer :: struct {
	buf: [dynamic]byte,
}

@(private = "file")
dbus_pad :: proc(w: ^Dbus_Writer, to: int) {
	for len(w.buf) % to != 0 {
		append(&w.buf, 0)
	}
}

@(private = "file")
dbus_u32 :: proc(w: ^Dbus_Writer, v: u32) {
	dbus_pad(w, 4)
	b: [4]byte
	endian.put_u32(b[:], .Little, v)
	append(&w.buf, ..b[:])
}

// A string or object path: its length, its bytes and a NUL.
@(private = "file")
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
@(private = "file")
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
// escaped) with the app's icon. Allocated with the temp allocator.
dbus_notify_message :: proc(serial: u32, app_id, title, body: string) -> []byte {
	w := Dbus_Writer{buf = make([dynamic]byte, context.temp_allocator)}
	dbus_string(&w, APP_NAME) // app_name
	dbus_u32(&w, 0) // replaces_id
	dbus_string(&w, app_id) // app_icon
	dbus_string(&w, title) // summary
	dbus_string(&w, body)
	actions_at, actions_start := dbus_array_begin(&w, 4)
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

// Nothing to tidy up: each notification has its own connection.
notifications_destroy :: proc(app: ^App) {}
