package app

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

DEFAULT_VOLUME :: 100
// mpv's own limit (volume-max): above 100% is a software boost.
MAX_VOLUME :: 130

// What's kept between runs: the splits last open with each watched channel, so
// watching it again brings them back, and the volume. Saved in
// ~/.config/twitch-app/layout.json.
Layout :: struct {
	// Watched channel -> the split channels, left to right. Owned.
	splits: map[string][dynamic]string,
	// 0 to MAX_VOLUME.
	volume: int,
	muted:  bool,
}

layout_destroy :: proc(l: ^Layout) {
	for channel, list in l.splits {
		delete(channel)
		for split in list {
			delete(split)
		}
		delete(list)
	}
	delete(l.splits)
}

@(private = "file")
layout_path :: proc() -> (path: string, ok: bool) {
	auth := auth_path() or_return
	joined, err := filepath.join({filepath.dir(auth), "layout.json"}, context.temp_allocator)
	return joined, err == nil
}

// A missing or unreadable file is an empty layout at full volume.
layout_load :: proc() -> (l: Layout) {
	l.volume = DEFAULT_VOLUME
	path, ok := layout_path()
	if !ok {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	parse_layout(data, &l)
	return
}

// Reads saved splits and volume into `l`, keeping only valid channel names.
parse_layout :: proc(data: []byte, l: ^Layout) -> bool {
	saved: struct {
		splits: map[string][]string,
		volume: int,
		muted:  bool,
	}
	if json.unmarshal(data, &saved, allocator = context.temp_allocator) != nil {
		log.warn("layout.json is unreadable; starting without saved splits")
		return false
	}
	// A file from before the volume was saved has none: keep the default, not 0.
	if value, err := json.parse(data, allocator = context.temp_allocator); err == nil {
		if obj, is_obj := value.(json.Object); is_obj && "volume" in obj {
			l.volume = clamp(saved.volume, 0, MAX_VOLUME)
		}
	}
	l.muted = saved.muted
	for channel, splits in saved.splits {
		if !valid_login(channel) {
			continue
		}
		list := make([dynamic]string)
		for split in splits {
			if valid_login(split) {
				append(&list, strings.clone(split))
			}
		}
		l.splits[strings.clone(channel)] = list
	}
	return true
}

layout_save :: proc(l: ^Layout) {
	path, ok := layout_path()
	if !ok {
		return
	}
	if err := os.make_directory_all(filepath.dir(path), {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		log.warnf("can't save splits: %v", err)
		return
	}
	data, err := json.marshal(l^, {pretty = true}, context.temp_allocator)
	if err != nil {
		return
	}
	if write_err := os.write_entire_file(path, data); write_err != nil {
		log.warnf("can't save splits: %v", write_err)
	}
}

// Records the splits open now for the watched channel, and saves.
layout_remember :: proc(app: ^App) {
	w := &app.watch
	l := &app.layout
	if w.channel == "" {
		return
	}
	if w.channel in l.splits {
		old_key, old := delete_key(&l.splits, w.channel)
		delete(old_key)
		for split in old {
			delete(split)
		}
		delete(old)
	}
	list := make([dynamic]string)
	for p in w.panes[1:] {
		if p.channel != "" {
			append(&list, strings.clone(p.channel))
		}
	}
	if len(list) > 0 {
		l.splits[strings.clone(w.channel)] = list
	} else {
		delete(list)
	}
	layout_save(l)
}

// The splits saved for `channel`.
layout_splits :: proc(app: ^App, channel: string) -> []string {
	list, found := app.layout.splits[channel]
	return list[:] if found else nil
}
