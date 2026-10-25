#+build linux
package app

import "core:strings"
import "core:testing"

@(test)
dbus_address_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path, abstract, ok := dbus_socket_path("unix:path=/run/user/1000/bus,guid=abc")
	testing.expect(t, ok && !abstract)
	testing.expect_value(t, path, "/run/user/1000/bus")
	path, abstract, ok = dbus_socket_path("tcp:host=x;unix:abstract=/tmp/dbus-%41b")
	testing.expect(t, ok && abstract)
	testing.expect_value(t, path, "/tmp/dbus-Ab")
	_, _, ok = dbus_socket_path("")
	testing.expect(t, !ok)
}

@(test)
dbus_notify_message_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg := dbus_notify_message(7, "lurker", "lurker", "a is live", "x", "Watch", "/tmp/a.png")
	testing.expect_value(t, msg[0], 'l')
	testing.expect_value(t, msg[1], DBUS_METHOD_CALL)
	testing.expect_value(t, dbus_message_size(msg), len(msg))
	testing.expect_value(t, notify_escape("a<b>&c"), "a&lt;b&gt;&amp;c")

	m, ok := dbus_parse(msg)
	testing.expect(t, ok)
	testing.expect_value(t, m.interface, "org.freedesktop.Notifications")
	testing.expect_value(t, m.member, "Notify")
	testing.expect_value(t, m.signature, "susssasa{sv}i")
	testing.expect_value(t, dbus_read_string(&m.body), APP_NAME)
	testing.expect_value(t, dbus_read_u32(&m.body), 0)
	testing.expect(t, m.body.ok)
}

// A signal from the notification server: an ID and, for "us", a string.
@(private = "file")
fake_signal :: proc(member, signature: string, id: u32, text := "") -> []byte {
	body := Dbus_Writer{buf = make([dynamic]byte, context.temp_allocator)}
	dbus_u32(&body, id)
	if signature == "us" {
		dbus_string(&body, text)
	} else {
		dbus_u32(&body, 2)
	}
	msg := dbus_method_call(9, "", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", member, signature, body.buf[:])
	msg[1] = DBUS_SIGNAL
	return msg
}

// Notify's reply to call `serial`: the notification's ID.
@(private = "file")
fake_reply :: proc(serial, id: u32) -> []byte {
	w := Dbus_Writer{buf = make([dynamic]byte, context.temp_allocator)}
	append(&w.buf, 'l', DBUS_METHOD_RETURN, 0, 1)
	dbus_u32(&w, 4) // body length
	dbus_u32(&w, 9)
	// Header fields: REPLY_SERIAL (5) as "u", then padding to 8, SIGNATURE (8) as "g".
	dbus_u32(&w, 15)
	append(&w.buf, 5, 1, 'u', 0)
	dbus_u32(&w, serial)
	append(&w.buf, 8, 1, 'g', 0, 1, 'u', 0)
	append(&w.buf, 0) // to 8
	dbus_u32(&w, id)
	return w.buf[:]
}

@(test)
notify_bus_click :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bus: Notify_Bus
	defer notify_bus_destroy(&bus)
	bus.pending[3] = strings.clone("moonmoon")

	// Notify's reply gives the notification's ID.
	reply := fake_reply(3, 42)
	m, ok := dbus_parse(reply)
	testing.expect(t, ok)
	testing.expect_value(t, m.reply_serial, 3)
	testing.expect(t, notify_bus_handle(&bus, reply) == nil)
	testing.expect_value(t, bus.shown[42], "moonmoon")
	testing.expect_value(t, len(bus.pending), 0)

	// Another app's notification isn't ours.
	testing.expect(t, notify_bus_handle(&bus, fake_signal("ActionInvoked", "us", 7, "default")) == nil)

	notify_bus_handle(&bus, fake_signal("ActivationToken", "us", 42, "tok"))
	click, clicked := notify_bus_handle(&bus, fake_signal("ActionInvoked", "us", 42, "default")).?
	testing.expect(t, clicked)
	testing.expect_value(t, click.login, "moonmoon")
	testing.expect_value(t, click.token, "tok")
	destroy_notify_click(click)

	notify_bus_handle(&bus, fake_signal("NotificationClosed", "uu", 42))
	testing.expect_value(t, len(bus.shown), 0)
	testing.expect_value(t, len(bus.tokens), 0)
}
