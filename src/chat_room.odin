package app

import "core:fmt"
import "core:strconv"
import "core:strings"

// A channel's chat settings, from ROOMSTATE.
Room_State :: struct {
	emote_only: bool,
	subs_only:  bool,
	// Only unique messages (Twitch's "r9k" mode).
	unique:     bool,
	// Minutes someone must have followed for; -1 when anyone can chat.
	followers:  int,
	// Seconds between someone's messages; 0 when off.
	slow:       int,
	known:      bool,
}

// What the signed-in user is in a channel, from USERSTATE's badges.
Chat_Self :: struct {
	broadcaster: bool,
	moderator:   bool,
	vip:         bool,
	subscriber:  bool,
}

// Applies a ROOMSTATE: the first after joining has every setting, later ones only
// what changed.
apply_roomstate :: proc(room: ^Room_State, msg: Irc_Message) {
	if !room.known {
		room^ = {followers = -1, known = true}
	}
	flag :: proc(msg: Irc_Message, key: string, into: ^bool) {
		if value, found := irc_tag(msg, key); found {
			into^ = value == "1"
		}
	}
	number :: proc(msg: Irc_Message, key: string, into: ^int) {
		if value, found := irc_tag(msg, key); found {
			if n, ok := strconv.parse_int(value, 10); ok {
				into^ = n
			}
		}
	}
	flag(msg, "emote-only", &room.emote_only)
	flag(msg, "subs-only", &room.subs_only)
	flag(msg, "r9k", &room.unique)
	number(msg, "followers-only", &room.followers)
	number(msg, "slow", &room.slow)
}

chat_self_from_tags :: proc(msg: Irc_Message) -> (s: Chat_Self) {
	badges, _ := irc_tag(msg, "badges")
	for badge in strings.split_iterator(&badges, ",") {
		set, _, _ := strings.partition(badge, "/")
		switch set {
		case "broadcaster":
			s.broadcaster = true
		case "moderator":
			s.moderator = true
		case "vip":
			s.vip = true
		case "subscriber", "founder":
			s.subscriber = true
		}
	}
	if m, _ := irc_tag(msg, "mod"); m == "1" {
		s.moderator = true
	}
	return
}

// Moderators, VIPs and the broadcaster aren't held to slow or subscriber-only mode.
chat_self_exempt :: proc(s: Chat_Self) -> bool {
	return s.broadcaster || s.moderator || s.vip
}

// "Slow 30s · Subscribers · Followers 10m": the modes that are on, or "". Allocated
// with the temp allocator.
room_modes_label :: proc(room: Room_State) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if room.slow > 0 {
		append(&parts, fmt.tprintf("Slow %s", format_duration(room.slow)))
	}
	if room.subs_only {
		append(&parts, "Subscribers only")
	}
	switch {
	case room.followers == 0:
		append(&parts, "Followers only")
	case room.followers > 0:
		append(&parts, fmt.tprintf("Followers only (%s)", format_duration(room.followers * 60)))
	}
	if room.emote_only {
		append(&parts, "Emote only")
	}
	if room.unique {
		append(&parts, "Unique messages")
	}
	return strings.join(parts[:], " · ", context.temp_allocator)
}
