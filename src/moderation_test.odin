package app

import "core:testing"

@(private = "file")
chat :: proc(line: string) -> Chat_Message {
	msg, _ := parse_irc(line)
	return privmsg_to_chat(msg)
}

@(private = "file")
moderation :: proc(line: string) -> Chat_Message {
	msg, _ := parse_irc(line)
	m, _ := moderation_message(msg)
	return m
}

@(test)
timeouts_and_bans_are_worded :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	timeout := moderation("@ban-duration=600;target-user-id=1 :tmi.twitch.tv CLEARCHAT #chan :spammer")
	defer destroy_chat_message(timeout)
	testing.expect_value(t, timeout.clear, Clear_Kind.User)
	testing.expect_value(t, timeout.clear_target, "spammer")
	testing.expect_value(t, timeout.fragments[0].text, "spammer has been timed out for 10m.")

	ban := moderation("@target-user-id=1 :tmi.twitch.tv CLEARCHAT #chan :spammer")
	defer destroy_chat_message(ban)
	testing.expect_value(t, ban.fragments[0].text, "spammer has been permanently banned.")

	all := moderation(":tmi.twitch.tv CLEARCHAT #chan")
	defer destroy_chat_message(all)
	testing.expect_value(t, all.clear, Clear_Kind.All)

	testing.expect_value(t, format_duration(45), "45s")
	testing.expect_value(t, format_duration(5400), "1h 30m")
	testing.expect_value(t, format_duration(7200), "2h")
	testing.expect_value(t, format_duration(1_209_600), "14d")
}

@(test)
moderation_fades_messages :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	assets: Assets
	defer emotes_destroy(&assets.emotes)
	v: Chat_View
	defer chat_view_destroy(&v)
	incoming := []Chat_Message {
		chat("@id=m1 :spammer!spammer@x PRIVMSG #chan :buy followers"),
		chat("@id=m2 :spammer!spammer@x PRIVMSG #chan :cheap"),
		chat("@id=m3 :friend!friend@x PRIVMSG #chan :hi @Me!"),
		moderation("@login=friend;target-msg-id=m3 :tmi.twitch.tv CLEARMSG #chan :hi"),
		moderation("@ban-duration=60 :tmi.twitch.tv CLEARCHAT #chan :spammer"),
	}
	added := chat_view_add(&v, &assets, 1, 300, incoming, self_login = "me")
	// For the header's unread count.
	testing.expect_value(t, added, 1)
	// The CLEARMSG leaves no line; the timeout does.
	testing.expect_value(t, len(v.messages), 4)
	testing.expect(t, v.messages[0].deleted)
	testing.expect(t, v.messages[1].deleted)
	testing.expect(t, v.messages[2].deleted)
	testing.expect(t, v.messages[2].mention)
	testing.expect(t, !v.messages[0].mention)
}

@(test)
mentions_match_whole_words :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := []struct {
		line: string,
		want: bool,
	} {
		{":a!a@x PRIVMSG #c :hey me", true},
		{":a!a@x PRIVMSG #c :@ME, look", true},
		{":a!a@x PRIVMSG #c :meme time", false},
		// Our own messages aren't mentions.
		{":me!me@x PRIVMSG #c :me", false},
	}
	for c in cases {
		m := chat(c.line)
		testing.expectf(t, mentions(&m, "me") == c.want, "%q", c.line)
		destroy_chat_message(m)
	}
}

@(test)
user_lookup_parses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":[{"id":"1","login":"lirik","display_name":"LIRIK","description":"hi",` +
		`"profile_image_url":"https://x/p.png","created_at":"2008-02-26T03:57:04Z","type":""}]}`
	u, ok := parse_user(transmute([]byte)body)
	defer destroy_user_info(u)
	testing.expect(t, ok)
	testing.expect_value(t, u.display_name, "LIRIK")
	testing.expect_value(t, u.created_at[:10], "2008-02-26")
	_, empty_ok := parse_user(transmute([]byte)string(`{"data":[]}`))
	testing.expect(t, !empty_ok)
}

@(test)
filters_match_words_and_senders :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m := chat("@display-name=LIRIK :lirik!lirik@x PRIVMSG #c :Good Morning chat")
	defer destroy_chat_message(m)
	testing.expect(t, message_matches(&m, parse_filter("morning")))
	testing.expect(t, message_matches(&m, parse_filter("GOOD chat")))
	testing.expect(t, message_matches(&m, parse_filter("from:lir")))
	testing.expect(t, message_matches(&m, parse_filter("from:@lirik morning")))
	testing.expect(t, !message_matches(&m, parse_filter("from:someone")))
	testing.expect(t, !message_matches(&m, parse_filter("evening")))
	sys := system_message("Joined #c")
	defer destroy_chat_message(sys)
	testing.expect(t, message_matches(&sys, parse_filter("joined")))
	testing.expect(t, !message_matches(&sys, parse_filter("from:lirik")))
}
