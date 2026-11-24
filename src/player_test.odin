package app

import "core:testing"

@(test)
audio_devices_keep_the_outputs_lurker_uses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	list: [dynamic]Audio_Device
	defer {
		audio_devices_clear(&list)
		delete(list)
	}
	text := `[{"name":"auto","description":"Autoselect device"},` +
		`{"name":"pipewire","description":"Default (pipewire)"},` +
		`{"name":"pipewire/bluez_output.E4.1","description":"Headphones"},` +
		`{"name":"pulse/bluez_output.E4.1","description":"Headphones"},` +
		`{"name":"pulse/alsa_output.usb","description":""}]`
	parse_audio_devices(text, &list)
	when ODIN_OS == .Linux {
		testing.expect_value(t, len(list), 2)
		testing.expect_value(t, list[0].name, "pulse/bluez_output.E4.1")
		testing.expect_value(t, list[0].description, "Headphones")
		// No description: the name stands in.
		testing.expect_value(t, list[1].description, "pulse/alsa_output.usb")
	} else {
		testing.expect_value(t, len(list), 4)
	}
	// A new list replaces the old; one that isn't JSON leaves none.
	parse_audio_devices("not json", &list)
	testing.expect_value(t, len(list), 0)
}
