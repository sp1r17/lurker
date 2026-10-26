package app

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// How many videos' positions are kept; the least recently watched go first.
WATCHED_MAX :: 500
// How often the position is noted while a video plays, and saved to disk.
WATCHED_NOTE_MS :: 10_000
WATCHED_SAVE_MS :: 60_000
// Positions closer than this to the start aren't worth resuming from, and ones
// closer to the end count as watched to the end.
WATCHED_MIN_SECONDS :: 30
WATCHED_END_SECONDS :: 60
// How long the "Resumed at" notice shows.
RESUME_NOTICE_MS :: 6000

// Where the user got to in a video.
Watched_Entry :: struct {
	position: int,
	length:   int,
	// When, in Unix seconds, for dropping the oldest.
	at:       i64,
}

// Where the user got to in each past broadcast, highlight and upload watched,
// saved in watched.json beside the layout.
Watched :: struct {
	// Keys owned.
	entries:  map[string]Watched_Entry,
	dirty:    bool,
	noted_at: int,
	saved_at: int,
}

watched_destroy :: proc(w: ^Watched) {
	for id in w.entries {
		delete(id)
	}
	delete(w.entries)
}

@(private = "file")
watched_path :: proc() -> (path: string, ok: bool) {
	layout := layout_path() or_return
	joined, err := filepath.join({filepath.dir(layout), "watched.json"}, context.temp_allocator)
	return joined, err == nil
}

watched_load :: proc() -> (w: Watched) {
	path, ok := watched_path()
	if !ok {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	saved: map[string]Watched_Entry
	if json.unmarshal(data, &saved, allocator = context.temp_allocator) != nil {
		log.warn("watched.json is unreadable; starting without resume positions")
		return
	}
	for id, entry in saved {
		w.entries[strings.clone(id)] = entry
	}
	return
}

watched_save :: proc(w: ^Watched) {
	if !w.dirty {
		return
	}
	path, ok := watched_path()
	if !ok {
		return
	}
	if err := os.make_directory_all(filepath.dir(path)); err != nil && err != .Exist {
		return
	}
	data, err := json.marshal(w.entries, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	if write_err := os.write_entire_file(path, data); write_err != nil {
		log.warnf("can't save %s: %v", path, write_err)
		return
	}
	w.dirty = false
}

// Notes that video `id` (`length` seconds long) is at `position`, dropping the
// least recently watched video once there are too many.
watched_set :: proc(w: ^Watched, id: string, position, length: int) {
	entry := Watched_Entry{position, length, time.to_unix_seconds(time.now())}
	if id in w.entries {
		w.entries[id] = entry
	} else {
		w.entries[strings.clone(id)] = entry
	}
	w.dirty = true
	if len(w.entries) <= WATCHED_MAX {
		return
	}
	Item :: struct {
		id: string,
		at: i64,
	}
	items := make([dynamic]Item, 0, len(w.entries), context.temp_allocator)
	for key, e in w.entries {
		append(&items, Item{key, e.at})
	}
	slice.sort_by(items[:], proc(a, b: Item) -> bool {return a.at < b.at})
	for item in items[:len(items) - WATCHED_MAX] {
		key, _ := delete_key(&w.entries, item.id)
		delete(key)
	}
}

// Where to start video `id`: where the user left off, unless that's too near
// either end to be worth it.
watched_resume_at :: proc(w: ^Watched, id: string, length: int) -> int {
	entry, found := w.entries[id]
	if !found || entry.position < WATCHED_MIN_SECONDS {
		return 0
	}
	if length > 0 && entry.position > length - WATCHED_END_SECONDS {
		return 0
	}
	return entry.position
}

// How much of video `id` was watched, 0 to 1 (1 for to the end), for its card.
watched_progress :: proc(w: ^Watched, id: string, length: int) -> f32 {
	entry, found := w.entries[id]
	if !found || length <= 0 {
		return 0
	}
	if entry.position > length - WATCHED_END_SECONDS {
		return 1
	}
	return clamp(f32(entry.position) / f32(length), 0, 1)
}

// While a video plays, notes its position every WATCHED_NOTE_MS and saves every
// WATCHED_SAVE_MS. Returns ms until it's next due, for the main loop's wait.
watched_tick :: proc(app: ^App) -> int {
	w := &app.watch
	ww := &app.watched
	if ww.dirty && app.assets.now_ms - ww.saved_at >= WATCHED_SAVE_MS {
		watched_save(ww)
		ww.saved_at = app.assets.now_ms
	}
	if app.screen != .Watch || !w.playing_vod || w.status != .Playing || w.vod.kind == .Clip {
		return -1
	}
	if app.assets.now_ms - ww.noted_at < WATCHED_NOTE_MS {
		return WATCHED_NOTE_MS - (app.assets.now_ms - ww.noted_at)
	}
	watched_note(app)
	return WATCHED_NOTE_MS
}

// Notes where the video playing is now (when leaving it, too).
watched_note :: proc(app: ^App) {
	w := &app.watch
	if !w.playing_vod || w.status != .Playing || w.vod.kind == .Clip {
		return
	}
	if pos, ok := player_position(&app.player); ok {
		watched_set(&app.watched, w.vod.id, int(pos), w.vod.length)
	}
	app.watched.noted_at = app.assets.now_ms
}
