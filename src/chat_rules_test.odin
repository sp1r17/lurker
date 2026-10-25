package app

import "core:strings"
import "core:testing"

@(private = "file")
chat :: proc(line: string) -> Chat_Message {
	msg, _ := parse_irc(line)
	return privmsg_to_chat(msg)
}

@(test)
phrases_match_whole_words :: proc(t: ^testing.T) {
	testing.expect(t, contains_words("hello world", "world"))
	testing.expect(t, contains_words("go team!", "go team"))
	testing.expect(t, !contains_words("swordfish", "word"))
	testing.expect(t, contains_words("a word, then", "word"))
	testing.expect(t, contains_words("lol :) ok", ":)"))
	testing.expect(t, !contains_words("anything", ""))
}

@(test)
rules_highlight_and_ignore :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	assets: Assets
	defer emotes_destroy(&assets.emotes)
	rules: Chat_Rules
	defer chat_rules_destroy(&rules)
	rule_add(&rules.highlights, "giveaway")
	rule_add(&rules.ignored, "spambot")
	rule_add(&rules.ignored, "spambot")
	testing.expect_value(t, len(rules.ignored), 1)
	v := Chat_View {
		rules = &rules,
	}
	defer chat_view_destroy(&v)
	incoming := []Chat_Message {
		chat("@id=1 :spambot!spambot@x PRIVMSG #chan :buy now"),
		chat("@id=2 :alice!alice@x PRIVMSG #chan :is the Giveaway on?"),
		chat("@id=3 :bob!bob@x PRIVMSG #chan :hi"),
		chat("@id=4 :me!me@x PRIVMSG #chan :my giveaway"),
	}
	added := chat_view_add(&v, &assets, 1, 300, incoming, "me")
	testing.expect_value(t, len(v.messages), 3)
	testing.expect(t, v.messages[0].mention)
	testing.expect(t, !v.messages[1].mention)
	// Our own message isn't highlighted for us.
	testing.expect(t, !v.messages[2].mention)
	testing.expect_value(t, added, 1)

	chat_view_remove_user(&v, "bob")
	testing.expect_value(t, len(v.messages), 2)
	testing.expect(t, rule_remove(&rules.ignored, "spambot"))
	testing.expect(t, !rule_remove(&rules.ignored, "spambot"))
}

@(test)
accents_are_labelled :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	first := chat("@first-msg=1;id=1 :a!a@x PRIVMSG #chan :hi")
	defer destroy_chat_message(first)
	testing.expect_value(t, first.accent, Message_Accent.First)
	testing.expect_value(t, first.label, "First message")

	cheer := chat("@bits=100;first-msg=1;id=2 :a!a@x PRIVMSG #chan :Cheer100 gg")
	defer destroy_chat_message(cheer)
	testing.expect_value(t, cheer.accent, Message_Accent.Cheer)
	testing.expect_value(t, cheer.label, "Cheered 100 bits")

	paid := chat("@id=3;pinned-chat-paid-amount=505;pinned-chat-paid-currency=USD;pinned-chat-paid-exponent=2 :a!a@x PRIVMSG #chan :hello")
	defer destroy_chat_message(paid)
	testing.expect_value(t, paid.accent, Message_Accent.Paid)
	testing.expect_value(t, paid.label, "Hype Chat · 5.05 USD")
	testing.expect_value(t, format_amount("1000", "0"), "1000")
	testing.expect_value(t, format_amount("7", "2"), "0.07")
}

@(test)
rules_are_saved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	data := `{"highlights":["  GG ","gg",""],"ignored":["nightbot","bad name"]}`
	testing.expect(t, parse_layout(transmute([]byte)string(data), &l))
	testing.expect_value(t, strings.join(l.chat.highlights[:], ",", context.temp_allocator), "gg")
	testing.expect_value(t, strings.join(l.chat.ignored[:], ",", context.temp_allocator), "nightbot")
}
