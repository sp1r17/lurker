package app

import "core:encoding/json"
import "core:fmt"
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
	// The stream stats show over the video (stream_stats.odin).
	stats:       bool,
	// The live chat is held back to match the stream's latency (chat_delay.odin).
	chat_sync:   bool,
	// With low latency: how much video mpv keeps in hand, in ms, against the
	// stream arriving unevenly (LOW_LATENCY_BUFFERS).
	latency_buffer_ms: int,
	// The highest quality to play, by height (MAX_HEIGHTS); 0 for no limit.
	max_height:  int,
	// What mpv does to the picture: debanding and sharper scaling.
	video_enhancement: Video_Enhancement,
	// Not playing the next clip when one ends (vod.odin).
	next_clip_off: bool,
	// Not reporting watch time to Twitch for channel points (points.odin).
	points_off:  bool,
	// Loudness evened out between streams, and within one (player_set_normalize).
	normalize_audio: bool,
	// Not lowering a live stream's quality when it keeps buffering (buffering.odin).
	auto_quality_off: bool,
	// Not claiming channel point bonuses (bonus.odin), or finished drops
	// (drops.odin).
	bonus_off:        bool,
	drops_off:        bool,
	// The audio output, by mpv's name ("" for the system's choice; owned), and
	// how much later the video shows for headphones that play sound late
	// (AUDIO_DELAYS, in ms).
	audio_device:    string,
	audio_delay_ms:  int,
	// How stream lists are ordered, and the tab the browse screen opens on.
	stream_sort: Stream_Sort,
	start_view:  Browse_View,
	// The chats were hidden last, for every channel.
	hide_chat:   bool,
	// MIN_TEXT_SIZE to MAX_TEXT_SIZE percent.
	text_size:   int,
	// Live notifications are turned off (notify.odin); and which channels they're
	// for: all followed ones but those muted, or (`notify_only`) only those chosen.
	// Logins, owned.
	notifications_off: bool,
	notify_only:       bool,
	// Also a notification when a followed live channel changes its title or
	// category (live_notifier_info_changes).
	notify_changes:    bool,
	notify_muted:      [dynamic]string,
	notify_chosen:     [dynamic]string,
	// Highlight phrases and ignored people, for every chat.
	chat:              Chat_Rules,
	// The chats over the video (O), and where, how big and how
	// see-through (chat_overlay.odin).
	chat_overlay:            bool,
	chat_overlay_position:   Chat_Overlay_Position,
	chat_overlay_size:       Chat_Overlay_Size,
	chat_overlay_background: Chat_Overlay_Background,
	// Where the chats over the video were dragged to, as x, y, width and height
	// shares of the screen; no width for the corner and size above.
	chat_overlay_box:        [4]f32,
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
	delete(l.audio_device)
	for list in ([]^[dynamic]string{&l.notify_muted, &l.notify_chosen}) {
		for login in list {
			delete(login)
		}
		delete(list^)
	}
}

// The audio delays offered (Layout.audio_delay_ms), in ms: Bluetooth
// headphones play sound about 100 to 300 ms late.
AUDIO_DELAYS :: [?]int{0, 100, 150, 200, 250, 300}

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
		stats:       bool,
		chat_sync:   bool,
		latency_buffer_ms: int,
		max_height:  int,
		// By name, so a name this version doesn't know is ignored rather than
		// making the whole file unreadable.
		video_enhancement: string,
		next_clip_off: bool,
		points_off:  bool,
		normalize_audio: bool,
		auto_quality_off: bool,
		bonus_off:        bool,
		drops_off:        bool,
		audio_device:    string,
		audio_delay_ms:  int,
		stream_sort: Stream_Sort,
		start_view:  Browse_View,
		hide_chat:   bool,
		text_size:   int,
		notifications_off: bool,
		notify_only:       bool,
		notify_changes:    bool,
		notify_muted:      []string,
		notify_chosen:     []string,
		highlights:  []string,
		ignored:     []string,
		chat_timestamps:      bool,
		chat_highlight_staff: bool,
		chat_hide_bots:       bool,
		chat_alternate_lines: bool,
		chat_hide_badges:     bool,
		chat_highlight_own:   bool,
		chat_separators:      bool,
		chat_still_emotes:    bool,
		chat_chatter_count:   bool,
		chat_mention_sound:   bool,
		chat_mention_flash:   bool,
		chat_pinned_off:      bool,
		chat_prediction_off:  bool,
		chat_poll_off:        bool,
		// Its name before 0.12 was released.
		chat_viewer_count:    bool,
		chat_overlay:            bool,
		chat_overlay_position:   string,
		chat_overlay_size:       string,
		chat_overlay_background: string,
		chat_overlay_box:        [4]f32,
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
	l.stats = saved.stats
	l.chat_sync = saved.chat_sync
	l.next_clip_off = saved.next_clip_off
	l.points_off = saved.points_off
	l.normalize_audio = saved.normalize_audio
	l.auto_quality_off = saved.auto_quality_off
	l.bonus_off = saved.bonus_off
	l.drops_off = saved.drops_off
	if saved.audio_device != "" {
		delete(l.audio_device)
		l.audio_device = strings.clone(saved.audio_device)
	}
	for ms in AUDIO_DELAYS {
		if saved.audio_delay_ms == ms {
			l.audio_delay_ms = ms
		}
	}
	// Only the values offered, so a hand-edited file can't set another.
	for ms in LOW_LATENCY_BUFFERS {
		if saved.latency_buffer_ms == ms {
			l.latency_buffer_ms = ms
		}
	}
	for h in MAX_HEIGHTS {
		if saved.max_height == h {
			l.max_height = h
		}
	}
	for v in Video_Enhancement {
		if saved.video_enhancement == fmt.tprint(v) {
			l.video_enhancement = v
		}
	}
	l.stream_sort = saved.stream_sort
	// Only a tab.
	for view in START_VIEWS {
		if saved.start_view == view {
			l.start_view = view
		}
	}
	l.hide_chat = saved.hide_chat
	l.notifications_off = saved.notifications_off
	l.notify_only = saved.notify_only
	l.notify_changes = saved.notify_changes
	for login in saved.notify_muted {
		if valid_login(login) {
			rule_add(&l.notify_muted, login)
		}
	}
	for login in saved.notify_chosen {
		if valid_login(login) {
			rule_add(&l.notify_chosen, login)
		}
	}
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
	l.chat.timestamps = saved.chat_timestamps
	l.chat.highlight_staff = saved.chat_highlight_staff
	l.chat.hide_bots = saved.chat_hide_bots
	l.chat.alternate_lines = saved.chat_alternate_lines
	l.chat.hide_badges = saved.chat_hide_badges
	l.chat.highlight_own = saved.chat_highlight_own
	l.chat.separators = saved.chat_separators
	l.chat.still_emotes = saved.chat_still_emotes
	l.chat.chatter_count = saved.chat_chatter_count || saved.chat_viewer_count
	l.chat.mention_sound = saved.chat_mention_sound
	l.chat.mention_flash = saved.chat_mention_flash
	l.chat.pinned_off = saved.chat_pinned_off
	l.chat.prediction_off = saved.chat_prediction_off
	l.chat.poll_off = saved.chat_poll_off
	l.chat_overlay = saved.chat_overlay
	l.chat_overlay_position = enum_from_name(Chat_Overlay_Position, saved.chat_overlay_position, Chat_Overlay_Position.Bottom_Right)
	l.chat_overlay_size = enum_from_name(Chat_Overlay_Size, saved.chat_overlay_size, Chat_Overlay_Size.Medium)
	l.chat_overlay_background = enum_from_name(Chat_Overlay_Background, saved.chat_overlay_background, Chat_Overlay_Background.Dim)
	l.chat_overlay_box = saved.chat_overlay_box
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
	// The quality is saved by name ("720p60").
	saved := struct {
		version:     int,
		splits:      map[string][dynamic]string,
		volume:      int,
		muted:       bool,
		quality:     string,
		low_latency: bool,
		raids_off:   bool,
		stats:       bool,
		chat_sync:   bool,
		latency_buffer_ms: int,
		max_height:  int,
		video_enhancement: string,
		next_clip_off: bool,
		points_off:  bool,
		normalize_audio: bool,
		auto_quality_off: bool,
		bonus_off:        bool,
		drops_off:        bool,
		audio_device:    string,
		audio_delay_ms:  int,
		stream_sort: Stream_Sort,
		start_view:  Browse_View,
		hide_chat:   bool,
		text_size:   int,
		notifications_off: bool,
		notify_only:       bool,
		notify_changes:    bool,
		notify_muted:      []string,
		notify_chosen:     []string,
		highlights:  []string,
		ignored:     []string,
		chat_timestamps:      bool,
		chat_highlight_staff: bool,
		chat_hide_bots:       bool,
		chat_alternate_lines: bool,
		chat_hide_badges:     bool,
		chat_highlight_own:   bool,
		chat_separators:      bool,
		chat_still_emotes:    bool,
		chat_chatter_count:   bool,
		chat_mention_sound:   bool,
		chat_mention_flash:   bool,
		chat_pinned_off:      bool,
		chat_prediction_off:  bool,
		chat_poll_off:        bool,
		chat_overlay:            bool,
		chat_overlay_position:   string,
		chat_overlay_size:       string,
		chat_overlay_background: string,
		chat_overlay_box:        [4]f32,
		update_checks_off: bool,
		skipped_version:   string,
		language:          string,
		language_hide:     bool,
	}{LAYOUT_VERSION, l.splits, l.volume, l.muted, quality_name(l.quality), l.low_latency, l.raids_off, l.stats, l.chat_sync, l.latency_buffer_ms, l.max_height, fmt.tprint(l.video_enhancement), l.next_clip_off, l.points_off, l.normalize_audio, l.auto_quality_off, l.bonus_off, l.drops_off, l.audio_device, l.audio_delay_ms, l.stream_sort, l.start_view, l.hide_chat, l.text_size, l.notifications_off, l.notify_only, l.notify_changes, l.notify_muted[:], l.notify_chosen[:], l.chat.highlights[:], l.chat.ignored[:], l.chat.timestamps, l.chat.highlight_staff, l.chat.hide_bots, l.chat.alternate_lines, l.chat.hide_badges, l.chat.highlight_own, l.chat.separators, l.chat.still_emotes, l.chat.chatter_count, l.chat.mention_sound, l.chat.mention_flash, l.chat.pinned_off, l.chat.prediction_off, l.chat.poll_off, l.chat_overlay, fmt.tprint(l.chat_overlay_position), fmt.tprint(l.chat_overlay_size), fmt.tprint(l.chat_overlay_background), l.chat_overlay_box, l.update_checks_off, l.skipped_version, l.language, l.language_hide}
	data, err := json.marshal(saved, {pretty = true, use_enum_names = true}, context.temp_allocator)
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
