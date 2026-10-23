package app

import "core:testing"

@(test)
irc_line_is_split :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, ok := parse_irc("@color=#FF0000;display-name=Foo :foo!foo@foo.tmi.twitch.tv PRIVMSG #chan :hello there\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, msg.tags, "color=#FF0000;display-name=Foo")
	testing.expect_value(t, msg.prefix, "foo!foo@foo.tmi.twitch.tv")
	testing.expect_value(t, msg.command, "PRIVMSG")
	testing.expect_value(t, len(msg.params), 2)
	testing.expect_value(t, msg.params[0], "#chan")
	testing.expect_value(t, irc_trailing(msg), "hello there")
	testing.expect_value(t, irc_nick(msg), "foo")

	ping, ping_ok := parse_irc("PING :tmi.twitch.tv")
	testing.expect(t, ping_ok)
	testing.expect_value(t, ping.command, "PING")
	testing.expect_value(t, irc_trailing(ping), "tmi.twitch.tv")

	_, empty_ok := parse_irc("")
	testing.expect(t, !empty_ok)
}

@(test)
irc_tags_are_unescaped :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, _ := parse_irc(`@system-msg=5\sraiders\sfrom\:\\x;empty= :tmi.twitch.tv USERNOTICE #chan`)
	value, found := irc_tag(msg, "system-msg")
	testing.expect(t, found)
	testing.expect_value(t, value, `5 raiders from;\x`)
	empty, empty_found := irc_tag(msg, "empty")
	testing.expect(t, empty_found)
	testing.expect_value(t, empty, "")
	_, missing := irc_tag(msg, "color")
	testing.expect(t, !missing)
}

@(test)
privmsg_becomes_chat_message :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, _ := parse_irc("@color=#00FF00;display-name=FooBar :foobar!foobar@x PRIVMSG #chan :hi")
	m := privmsg_to_chat(msg)
	defer destroy_chat_message(m)
	testing.expect_value(t, m.kind, Chat_Message_Kind.Chat)
	testing.expect_value(t, m.name, "FooBar")
	testing.expect_value(t, m.color, Color{0, 255, 0, 255})
	testing.expect_value(t, len(m.fragments), 1)
	testing.expect_value(t, m.fragments[0].text, "hi")
}

@(test)
action_and_localized_names :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, _ := parse_irc("@display-name=이름 :someone!someone@x PRIVMSG #chan :\x01ACTION waves\x01")
	m := privmsg_to_chat(msg)
	defer destroy_chat_message(m)
	testing.expect_value(t, m.kind, Chat_Message_Kind.Action)
	testing.expect_value(t, m.name, "이름 (someone)")
	testing.expect_value(t, m.fragments[0].text, "waves")
	// No colour tag: a default colour, the same every time for this login.
	testing.expect_value(t, m.color, readable_on_dark(default_name_color("someone")))
}

@(test)
usernotice_sender_comes_from_login_tag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, _ := parse_irc("@login=subber;display-name=Subber :tmi.twitch.tv USERNOTICE #chan :great stream")
	m := privmsg_to_chat(msg)
	defer destroy_chat_message(m)
	testing.expect_value(t, m.name, "Subber")
	testing.expect_value(t, m.fragments[0].text, "great stream")
}

@(test)
dark_colors_are_lightened :: proc(t: ^testing.T) {
	blue, ok := parse_hex_color("#0000FF")
	testing.expect(t, ok)
	light := readable_on_dark(blue)
	testing.expect(t, 0.299 * f32(light.r) + 0.587 * f32(light.g) + 0.114 * f32(light.b) >= MIN_NAME_LUMA - 1)
	testing.expect(t, light.b == 255)
	// Bright enough already: unchanged.
	testing.expect_value(t, readable_on_dark({0, 255, 127, 255}), Color{0, 255, 127, 255})
	_, bad := parse_hex_color("red")
	testing.expect(t, !bad)
}

@(test)
replies_show_what_they_answer :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, _ := parse_irc(
		"@display-name=Bar;reply-parent-display-name=Foo;reply-parent-user-login=foo;reply-parent-msg-body=is\\sit\\slive? :bar!bar@x PRIVMSG #chan :@Foo yes it is",
	)
	m := privmsg_to_chat(msg)
	defer destroy_chat_message(m)
	testing.expect_value(t, m.reply, "Replying to @Foo: is it live?")
	// The "@Foo" Twitch adds is left out: the reply line says it.
	testing.expect_value(t, len(m.fragments), 1)
	testing.expect_value(t, m.fragments[0].text, "yes it is")
	testing.expect(t, mentions(&m, "foo"))
	testing.expect(t, !mentions(&m, "baz"))
}
