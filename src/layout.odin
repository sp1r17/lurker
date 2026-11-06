package app

import "core:encoding/json"
import "core:strings"

DEFAULT_VOLUME :: 100
// mpv's own limit (volume-max): above 100% is a software boost.
MAX_VOLUME :: 130
// Text size as a percentage of the normal size (Ctrl+= and Ctrl+-).
DEFAULT_TEXT_SIZE :: 100
MIN_TEXT_SIZE :: 70
MAX_TEXT_SIZE :: 200
TEXT_SIZE_STEP :: 10
// How long the text size shows after a change.
TEXT_SIZE_OSD_MS :: 1500

// What's kept between runs: the splits last open with each watched channel, so
// watching it again brings them back, the volume, the quality, whether the
// chats are hidden and the text size. Saved in ~/.config/lurker/layout.json.
Layout :: struct {
	// Watched channel -> the split channels, left to right. Owned.
	splits: map[string][dynamic]string,
	// 0 to MAX_VOLUME.
	volume:  int,
	muted:   bool,
	// The stream quality picked last, for every channel.
	quality:     Quality,
	low_latency: bool,
	// Not following the watched channel's raids (raid.odin).
	raids_off:   bool,
	// The chats were hidden last, for every channel.
	hide_chat:   bool,
	// MIN_TEXT_SIZE to MAX_TEXT_SIZE percent.
	text_size:   int,
	// Live notifications are turned off (notify.odin).
	notifications_off: bool,
	// Highlight phrases and ignored people, for every chat.
	chat:              Chat_Rules,
	// Not checking for new versions (update.odin), and the version the user chose
	// to skip (owned).
	update_checks_off: bool,
	skipped_version:   string,
	// The primary language (a Twitch language code; "" for any; owned), and
	// whether streams in others are hidden rather than grayed out (language.odin).
	language:          string,
	language_hide:     bool,
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
	chat_rules_destroy(&l.chat)
	delete(l.skipped_version)
	delete(l.language)
}

// The format layout.json is saved in (see saved.odin). 1 added the version.
LAYOUT_VERSION :: 1

layout_path :: proc() -> (path: string, ok: bool) {
	return state_path("layout.json")
}

// A missing or unreadable file is an empty layout at full volume.
layout_load :: proc() -> (l: Layout) {
	l.volume = DEFAULT_VOLUME
	l.text_size = DEFAULT_TEXT_SIZE
	path, ok := layout_path()
	if !ok {
		return
	}
	data, _, read := saved_read(path, LAYOUT_VERSION)
	if read == .Read && !parse_layout(data, &l) {
		saved_unreadable(path)
	}
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
		raids_off:   bool,
		hide_chat:   bool,
		text_size:   int,
		notifications_off: bool,
		highlights:  []string,
		ignored:     []string,
		update_checks_off: bool,
		skipped_version:   string,
		language:          string,
		language_hide:     bool,
	}
	if json.unmarshal(data, &saved, allocator = context.temp_allocator) != nil {
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
	l.raids_off = saved.raids_off
	l.hide_chat = saved.hide_chat
	l.notifications_off = saved.notifications_off
	l.update_checks_off = saved.update_checks_off
	if language_name(saved.language) != "" {
		delete(l.language)
		l.language = strings.clone(saved.language)
	}
	l.language_hide = saved.language_hide
	if _, ok := parse_version(saved.skipped_version); ok {
		delete(l.skipped_version)
		l.skipped_version = strings.clone(saved.skipped_version)
	}
	for phrase in saved.highlights {
		rule_add(&l.chat.highlights, strings.to_lower(strings.trim_space(phrase), context.temp_allocator))
	}
	for login in saved.ignored {
		if valid_login(login) {
			rule_add(&l.chat.ignored, login)
		}
	}
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
	// The quality is saved by name, so reordering the enum can't change it.
	saved := struct {
		version:     int,
		splits:      map[string][dynamic]string,
		volume:      int,
		muted:       bool,
		quality:     string,
		low_latency: bool,
		raids_off:   bool,
		hide_chat:   bool,
		text_size:   int,
		notifications_off: bool,
		highlights:  []string,
		ignored:     []string,
		update_checks_off: bool,
		skipped_version:   string,
		language:          string,
		language_hide:     bool,
	}{LAYOUT_VERSION, l.splits, l.volume, l.muted, QUALITY_LABELS[l.quality], l.low_latency, l.raids_off, l.hide_chat, l.text_size, l.notifications_off, l.chat.highlights[:], l.chat.ignored[:], l.update_checks_off, l.skipped_version, l.language, l.language_hide}
	data, err := json.marshal(saved, {pretty = true}, context.temp_allocator)
	if err != nil {
		return
	}
	save_file(path, data)
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
