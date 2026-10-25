#+build linux
package app

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
	msg := dbus_notify_message(7, "lurker", "a is live", "x")
	testing.expect_value(t, msg[0], 'l')
	testing.expect_value(t, msg[1], DBUS_METHOD_CALL)
	testing.expect_value(t, dbus_message_size(msg), len(msg))
	testing.expect_value(t, notify_escape("a<b>&c"), "a&lt;b&gt;&amp;c")
}
