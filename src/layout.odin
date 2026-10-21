package app

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

DEFAULT_VOLUME :: 100
// mpv's own limit (volume-max): above 100% is a software boost.
MAX_VOLUME :: 130
// Text size as a percentage of the normal size (Ctrl+= and Ctrl+-).
DEFAULT_TEXT_SIZE :: 100
MIN_TEXT_SIZE :: 70
MAX_TEXT_SIZE :: 200
TEXT_SIZE_STEP :: 10

// What's kept between runs: the splits last open with each watched channel, so
// watching it again brings them back, the volume, the quality, whether the
// chats are hidden and the text size. Saved in ~/.config/twitch-app/layout.json.
Layout :: struct {
	// Watched channel -> the split channels, left to right. Owned.
	splits: map[string][dynamic]string,
	// 0 to MAX_VOLUME.
	volume:  int,
	muted:   bool,
	// The stream quality picked last, for every channel.
	quality:     Quality,
	low_latency: bool,
	// The chats were hidden last, for every channel.
	hide_chat:   bool,
	// MIN_TEXT_SIZE to MAX_TEXT_SIZE percent.
	text_size:   int,
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
	l.text_size = DEFAULT_TEXT_SIZE
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
		volume:      int,
		muted:       bool,
		quality:     string,
		low_latency: bool,
		hide_chat:   bool,
		text_size:   int,
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
	l.quality = quality_from_label(saved.quality)
	l.low_latency = saved.low_latency
	l.hide_chat = saved.hide_chat
	// A file from before the text size was saved has none (0): keep the default.
	if saved.text_size != 0 {
		l.text_size = clamp(saved.text_size, MIN_TEXT_SIZE, MAX_TEXT_SIZE)
	}
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
	// The quality is saved by name, so reordering the enum can't change it.
	saved := struct {
		splits:      map[string][dynamic]string,
		volume:      int,
		muted:       bool,
		quality:     string,
		low_latency: bool,
		hide_chat:   bool,
		text_size:   int,
	}{l.splits, l.volume, l.muted, QUALITY_LABELS[l.quality], l.low_latency, l.hide_chat, l.text_size}
	data, err := json.marshal(saved, {pretty = true}, context.temp_allocator)
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
