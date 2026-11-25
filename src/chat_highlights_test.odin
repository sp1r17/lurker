package app

import "core:testing"

@(private = "file")
line :: proc(raw: string) -> Chat_Message {
	msg, _ := parse_irc(raw)
	return privmsg_to_chat(msg)
}

@(test)
phrases_can_be_regular_expressions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rules: Chat_Rules
	defer chat_rules_destroy(&rules)
	for phrase in ([]string{"GG", "/\\bW+\\b/", "/clip ?it/i"}) {
		rule_add(&rules.highlights, normalize_phrase(phrase))
	}
	// A plain phrase is kept lowercase; an expression as typed.
	testing.expect_value(t, rules.highlights[0], "gg")
	testing.expect_value(t, rules.highlights[1], "/\\bW+\\b/")
	Case :: struct {
		text: string,
		want: bool,
	}
	cases := []Case {
		{"that was a gg", true},
		// Whole words only, for plain phrases.
		{"eggs", false},
		{"WWWW", true},
		// Case-sensitive without the i.
		{"www", false},
		{"CLIP IT", true},
		{"clipit", true},
		{"nothing here", false},
	}
	for c in cases {
		m := line(fmt_privmsg(c.text))
		testing.expectf(t, highlighted(&m, &rules) == c.want, "%q: want %v", c.text, c.want)
		destroy_chat_message(m)
	}
	// Changing the phrases is picked up.
	rule_remove(&rules.highlights, "gg")
	m := line(fmt_privmsg("gg"))
	defer destroy_chat_message(m)
	testing.expect(t, !highlighted(&m, &rules))
}

@(private = "file")
fmt_privmsg :: proc(text: string) -> string {
	return concat("@id=1 :bob!bob@x PRIVMSG #chan :", text)
}

@(private = "file")
concat :: proc(a, b: string) -> string {
	out := make([]byte, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(test)
broken_expressions_stay_phrases :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect(t, !phrase_is_regex("/(unclosed/"))
	testing.expect(t, !phrase_is_regex("/me"))
	testing.expect_value(t, normalize_phrase("/Me"), "/me")
	testing.expect(t, phrase_is_regex("/a+b/i"))
}

@(test)
people_and_badges_get_their_colours :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rules: Chat_Rules
	defer chat_rules_destroy(&rules)
	highlight_entry_add(&rules.people, "alice")
	highlight_entry_add(&rules.badges, badge_set_name("VIP"))
	highlight_entry_add(&rules.badges, badge_set_name("sub"))
	// The same twice is kept once; each new one is the next colour.
	highlight_entry_add(&rules.badges, "vip")
	testing.expect_value(t, len(rules.badges), 2)
	testing.expect_value(t, rules.badges[1].name, "subscriber")
	testing.expect_value(t, rules.badges[1].color, Highlight_Color.Orange)
	highlight_entry_recolor(&rules.badges, 1)
	testing.expect_value(t, rules.badges[1].color, Highlight_Color.Yellow)

	alice := line("@badges=subscriber/12;id=1 :alice!alice@x PRIVMSG #chan :hi")
	defer destroy_chat_message(alice)
	color, ok := custom_highlight(&alice, &rules)
	// The person's colour wins over their badge's.
	testing.expect(t, ok && color == HIGHLIGHT_BACKGROUNDS[.Red])
	sub := line("@badges=vip/1,subscriber/3;id=2 :bob!bob@x PRIVMSG #chan :hi")
	defer destroy_chat_message(sub)
	color, ok = custom_highlight(&sub, &rules)
	// The first chosen badge it has: vip before subscriber.
	testing.expect(t, ok && color == HIGHLIGHT_BACKGROUNDS[.Red])
	plain := line("@id=3 :carol!carol@x PRIVMSG #chan :hi")
	defer destroy_chat_message(plain)
	_, ok = custom_highlight(&plain, &rules)
	testing.expect(t, !ok)
	testing.expect_value(t, badge_set_name("not a badge!"), "")
}
