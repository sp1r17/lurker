package app

import "core:os"
import "core:strings"
import "core:testing"

// Points saved state at a new temporary folder for the test's thread. Remove it
// with end_test_state_dir.
@(private = "file")
test_state_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "lurker-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	state_dir_override = dir
	return dir
}

@(private = "file")
end_test_state_dir :: proc(dir: string) {
	state_dir_override = ""
	_ = os.remove_all(dir)
	delete(dir)
}

@(private = "file")
write :: proc(name, text: string) {
	path, _ := state_path(name)
	_ = os.write_entire_file(path, text)
}

@(private = "file")
read :: proc(name: string) -> string {
	path, _ := state_path(name)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

@(private = "file")
exists :: proc(name: string) -> bool {
	path, _ := state_path(name)
	return os.exists(path)
}

@(test)
saved_version_reads_the_field :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := []struct {
		data:    string,
		version: int,
		ok:      bool,
	} {
		{`{}`, 0, true},
		{`{"splits":{}}`, 0, true},
		{`{"version":1}`, 1, true},
		{`{"version":7,"volume":3}`, 7, true},
		{`[1, 2]`, 0, false},
		{`{"volume":`, 0, false},
		{``, 0, false},
	}
	for c in cases {
		version, ok := saved_version(transmute([]byte)c.data)
		testing.expectf(t, version == c.version && ok == c.ok, "%q: got %d, %v", c.data, version, ok)
	}
}

@(test)
layout_saves_its_version_and_reads_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := test_state_dir(t)
	defer end_test_state_dir(dir)

	l := layout_load()
	defer layout_destroy(&l)
	l.volume = 42
	l.low_latency = true
	rule_add(&l.chat.highlights, "giveaway")
	layout_save(&l)
	version, _ := saved_version(transmute([]byte)read("layout.json"))
	testing.expect_value(t, version, LAYOUT_VERSION)

	again := layout_load()
	defer layout_destroy(&again)
	testing.expect_value(t, again.volume, 42)
	testing.expect(t, again.low_latency)
	testing.expect_value(t, len(again.chat.highlights), 1)
	// Only the file itself: the temporary one was renamed into place.
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect_value(t, len(entries), 1)
}

@(test)
layout_from_before_versions_still_loads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := test_state_dir(t)
	defer end_test_state_dir(dir)

	// As 0.7.0 saved it.
	write("layout.json", `{"splits":{"lirik":["northernlion"]},"volume":80,"quality":"720p","text_size":120,"language":"en"}`)
	l := layout_load()
	defer layout_destroy(&l)
	testing.expect_value(t, l.volume, 80)
	testing.expect_value(t, l.quality, Quality.P720)
	testing.expect_value(t, l.text_size, 120)
	testing.expect_value(t, l.language, "en")
	testing.expect_value(t, len(layout_splits_of(&l, "lirik")), 1)
	testing.expect(t, !exists("layout.json.unreadable"))
}

@(private = "file")
layout_splits_of :: proc(l: ^Layout, channel: string) -> []string {
	list, found := l.splits[channel]
	return list[:] if found else nil
}

@(test)
unreadable_layout_is_kept_before_saving_over :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := test_state_dir(t)
	defer end_test_state_dir(dir)

	broken := `{"volume": 80, "splits": {`
	write("layout.json", broken)
	l := layout_load()
	defer layout_destroy(&l)
	testing.expect_value(t, l.volume, DEFAULT_VOLUME)
	testing.expect_value(t, read("layout.json.unreadable"), broken)
	layout_save(&l)
	testing.expect_value(t, read("layout.json.unreadable"), broken)

	// Valid JSON of the wrong shape counts too.
	write("blocked.json", `{"channels": "not a list"}`)
	bl := blocked_load()
	defer blocked_destroy(&bl)
	testing.expect(t, exists("blocked.json.unreadable"))
}

@(test)
newer_layout_is_kept_and_read_as_far_as_possible :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := test_state_dir(t)
	defer end_test_state_dir(dir)

	newer := `{"version": 99, "volume": 50, "something_new": true}`
	write("layout.json", newer)
	l := layout_load()
	defer layout_destroy(&l)
	testing.expect_value(t, l.volume, 50)
	testing.expect_value(t, read("layout.json.v99"), newer)
	testing.expect(t, !exists("layout.json.unreadable"))
}

@(test)
blocked_saves_its_version_and_reads_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := test_state_dir(t)
	defer end_test_state_dir(dir)

	// As 0.7.0 saved it.
	write("blocked.json", `{"channels":["somechannel"],"categories":["Just Chatting"]}`)
	bl := blocked_load()
	defer blocked_destroy(&bl)
	testing.expect(t, is_blocked(&bl, .Channel, "somechannel"))
	testing.expect(t, is_blocked(&bl, .Category, "Just Chatting"))
	blocked_add(&bl, .Channel, "another")
	blocked_save(&bl)
	version, _ := saved_version(transmute([]byte)read("blocked.json"))
	testing.expect_value(t, version, BLOCKED_VERSION)

	again := blocked_load()
	defer blocked_destroy(&again)
	testing.expect(t, is_blocked(&again, .Channel, "another"))
	testing.expect(t, is_blocked(&again, .Category, "Just Chatting"))
}

@(test)
watched_moves_positions_under_videos :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := test_state_dir(t)
	defer end_test_state_dir(dir)

	// As 0.7.0 saved it: the positions at the top level.
	write("watched.json", `{"2001":{"position":600,"length":3600,"at":1761000000}}`)
	w := watched_load()
	defer watched_destroy(&w)
	testing.expect_value(t, w.entries["2001"].position, 600)
	w.dirty = true
	watched_save(&w)
	saved := read("watched.json")
	version, _ := saved_version(transmute([]byte)saved)
	testing.expect_value(t, version, WATCHED_VERSION)
	testing.expect(t, strings.contains(saved, `"videos"`))

	again := watched_load()
	defer watched_destroy(&again)
	testing.expect_value(t, len(again.entries), 1)
	testing.expect_value(t, again.entries["2001"].length, 3600)
}
