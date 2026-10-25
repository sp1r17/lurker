package app

import "core:testing"

@(test)
roomstate_updates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	room: Room_State
	msg, _ := parse_irc("@emote-only=0;followers-only=-1;r9k=0;room-id=1;slow=0;subs-only=0 :tmi.twitch.tv ROOMSTATE #chan")
	apply_roomstate(&room, msg)
	testing.expect(t, room.known)
	testing.expect_value(t, room_modes_label(room), "")

	msg, _ = parse_irc("@room-id=1;slow=30 :tmi.twitch.tv ROOMSTATE #chan")
	apply_roomstate(&room, msg)
	msg, _ = parse_irc("@followers-only=10;room-id=1 :tmi.twitch.tv ROOMSTATE #chan")
	apply_roomstate(&room, msg)
	msg, _ = parse_irc("@room-id=1;subs-only=1 :tmi.twitch.tv ROOMSTATE #chan")
	apply_roomstate(&room, msg)
	testing.expect_value(t, room_modes_label(room), "Slow 30s · Subscribers only · Followers only (10m)")

	msg, _ = parse_irc("@followers-only=-1;room-id=1;slow=0;subs-only=0 :tmi.twitch.tv ROOMSTATE #chan")
	apply_roomstate(&room, msg)
	testing.expect_value(t, room_modes_label(room), "")
}

@(test)
chat_self_reads_badges :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, _ := parse_irc("@badges=moderator/1,subscriber/12;mod=1 :tmi.twitch.tv USERSTATE #chan")
	s := chat_self_from_tags(msg)
	testing.expect(t, s.moderator && s.subscriber && !s.vip && !s.broadcaster)
	testing.expect(t, chat_self_exempt(s))

	msg, _ = parse_irc("@badges=founder/0;mod=0 :tmi.twitch.tv USERSTATE #chan")
	s = chat_self_from_tags(msg)
	testing.expect(t, s.subscriber && !chat_self_exempt(s))
}
