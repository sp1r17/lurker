package app

import "core:strings"
import "core:testing"

@(test)
nicknames_are_typed_and_shown :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		typed, login, nickname: string,
		ok:                     bool,
	}
	cases := []Case {
		{"@Lirik -> The Lord", "lirik", "The Lord", true},
		{"moonmoon  Moon2", "moonmoon", "Moon2", true},
		{"moonmoon ->  ", "", "", false},
		{"justaname", "", "", false},
		{"bad name! -> x", "", "", false},
	}
	for c in cases {
		login, nickname, ok := parse_nickname(c.typed)
		testing.expectf(t, ok == c.ok, "%q: ok %v", c.typed, ok)
		if ok && c.ok {
			testing.expect_value(t, login, c.login)
			testing.expect_value(t, nickname, c.nickname)
		}
	}

	rules: Chat_Rules
	defer chat_rules_destroy(&rules)
	nickname_set(&rules.nicknames, "lirik", "Lord")
	nickname_set(&rules.nicknames, "lirik", "The Lord")
	testing.expect_value(t, len(rules.nicknames), 1)
	msg, _ := parse_irc("@id=1;display-name=LIRIK :lirik!lirik@x PRIVMSG #chan :morning chat")
	m := privmsg_to_chat(msg)
	defer destroy_chat_message(m)
	testing.expect_value(t, shown_name(&m, &rules), "The Lord")
	testing.expect_value(t, shown_name(&m, nil), "LIRIK")
	// Found by the nickname, and still by the name.
	testing.expect(t, message_matches(&m, parse_filter("from:the"), &rules))
	testing.expect(t, message_matches(&m, parse_filter("from:lir"), &rules))
	testing.expect_value(t, nickname_entries(rules.nicknames[:])[0], "lirik -> The Lord")
	nickname_remove(&rules.nicknames, 0)
	testing.expect_value(t, shown_name(&m, &rules), "LIRIK")
}

@(test)
nicknames_are_saved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	data := `{"nicknames":[{"login":"Lirik","nickname":" Lord "},{"login":"bad name","nickname":"x"},{"login":"a","nickname":""}]}`
	testing.expect(t, parse_layout(transmute([]byte)string(data), &l))
	testing.expect_value(t, strings.join(nickname_entries(l.chat.nicknames[:]), ",", context.temp_allocator), "lirik -> Lord")
}
