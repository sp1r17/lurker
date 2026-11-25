package app

import "core:fmt"
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
	added, _ := chat_view_add(&v, &assets, 1, 300, incoming, "me")
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

@(test)
shared_chat_source_is_kept :: proc(t: ^testing.T) {
	other := chat("@id=1;room-id=100;source-room-id=200 :a!a@x PRIVMSG #chan :hi from the other channel")
	defer destroy_chat_message(other)
	testing.expect_value(t, other.source_room, "200")
	own := chat("@id=2;room-id=100;source-room-id=100 :b!b@x PRIVMSG #chan :hi from here")
	defer destroy_chat_message(own)
	testing.expect_value(t, own.source_room, "")
	plain := chat("@id=3;room-id=100 :c!c@x PRIVMSG #chan :no shared chat")
	defer destroy_chat_message(plain)
	testing.expect_value(t, plain.source_room, "")
}

@(test)
old_messages_go_in_batches :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	assets: Assets
	defer emotes_destroy(&assets.emotes)
	v: Chat_View
	defer chat_view_destroy(&v)
	add :: proc(v: ^Chat_View, a: ^Assets, from, n: int) {
		for i in from ..< from + n {
			m := chat(fmt.tprintf("@id=%d :a!a@x PRIVMSG #chan :%d", i, i))
			chat_view_add(v, a, 1, 300, {m})
		}
	}
	// Past the cap, the oldest stay until a whole batch is over it.
	add(&v, &assets, 0, CHAT_MAX_MESSAGES + CHAT_TRIM_BATCH - 1)
	testing.expect_value(t, len(v.messages), CHAT_MAX_MESSAGES + CHAT_TRIM_BATCH - 1)
	add(&v, &assets, CHAT_MAX_MESSAGES + CHAT_TRIM_BATCH - 1, 1)
	testing.expect_value(t, len(v.messages), CHAT_MAX_MESSAGES)
	// The newest are kept, in order.
	testing.expect_value(t, v.messages[0].id, fmt.tprint(CHAT_TRIM_BATCH))
	testing.expect_value(t, v.messages[len(v.messages) - 1].id, fmt.tprint(CHAT_MAX_MESSAGES + CHAT_TRIM_BATCH - 1))

	// Someone ignored: theirs go, the rest stay in order.
	add_one :: proc(v: ^Chat_View, a: ^Assets, line: string) {
		chat_view_add(v, a, 1, 300, {chat(line)})
	}
	add_one(&v, &assets, "@id=x1 :bob!bob@x PRIVMSG #chan :one")
	add_one(&v, &assets, "@id=x2 :a!a@x PRIVMSG #chan :two")
	add_one(&v, &assets, "@id=x3 :bob!bob@x PRIVMSG #chan :three")
	n := len(v.messages)
	chat_view_remove_user(&v, "bob")
	testing.expect_value(t, len(v.messages), n - 2)
	testing.expect_value(t, v.messages[len(v.messages) - 1].id, "x2")
}

@(test)
only_live_mentions_alert :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	assets: Assets
	defer emotes_destroy(&assets.emotes)
	v: Chat_View
	defer chat_view_destroy(&v)
	// Said before the chat joined: counted, but no sound for it.
	old := chat("@id=1 :alice!alice@x PRIVMSG #chan :hi @me")
	old.historical = true
	added, alerts := chat_view_add(&v, &assets, 1, 300, []Chat_Message{old, chat("@id=2 :bob!bob@x PRIVMSG #chan :@me hello"), chat("@id=3 :carol!carol@x PRIVMSG #chan :hi")}, "me")
	testing.expect_value(t, added, 2)
	testing.expect_value(t, alerts, 1)
}
