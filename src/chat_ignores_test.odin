package app

import "core:strings"
import "core:testing"

@(private = "file")
chat :: proc(line: string) -> Chat_Message {
	msg, _ := parse_irc(line)
	return privmsg_to_chat(msg)
}

@(test)
ignore_entries_are_split_and_kept :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		typed, kept: string,
	}
	cases := []Case {
		{"  Spoilers ", "spoilers"},
		{"Bad Word->  nice word ", "bad word -> nice word"},
		{"gg ->", "gg ->"},
		// The arrow inside an expression is part of it.
		{"/a->b/i -> c", "/a->b/i -> c"},
		{"/a->b/", "/a->b/"},
		{"-> nothing", ""},
		{"   ", ""},
	}
	for c in cases {
		testing.expectf(t, normalize_ignore(c.typed) == c.kept, "%q: got %q, want %q", c.typed, normalize_ignore(c.typed), c.kept)
	}
	phrase, replacement, replaces := split_ignore("/x+/ -> y")
	testing.expect_value(t, phrase, "/x+/")
	testing.expect_value(t, replacement, "y")
	testing.expect(t, replaces)
}

@(test)
ignored_phrases_hide_or_replace :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	assets: Assets
	defer emotes_destroy(&assets.emotes)
	rules: Chat_Rules
	defer chat_rules_destroy(&rules)
	for typed in ([]string{"spoiler", "/^!\\w+/", "Bad -> good", "/l+o+l+/i -> haha", "/^w/ -> v", "um ->"}) {
		rule_add(&rules.ignored_phrases, normalize_ignore(typed))
	}
	v := Chat_View {
		rules = &rules,
	}
	defer chat_view_destroy(&v)
	incoming := []Chat_Message {
		chat("@id=1 :a!a@x PRIVMSG #chan :big SPOILER ahead"),
		chat("@id=2 :a!a@x PRIVMSG #chan :!commands"),
		// Whole words only.
		chat("@id=3 :a!a@x PRIVMSG #chan :spoilers are fine"),
		chat("@id=4 :a!a@x PRIVMSG #chan :bad, BAD and badger"),
		chat("@id=5 :a!a@x PRIVMSG #chan :LOOL lol"),
		// Anchored: only the first w.
		chat("@id=6 :a!a@x PRIVMSG #chan :www"),
		chat("@id=7 :a!a@x PRIVMSG #chan :um so um yes"),
		// Our own messages are left as they are.
		chat("@id=8 :me!me@x PRIVMSG #chan :spoiler, bad"),
	}
	chat_view_add(&v, &assets, 1, 300, incoming, "me")
	want := []string{"spoilers are fine", "good, good and badger", "haha haha", "vww", "so yes", "spoiler, bad"}
	testing.expect_value(t, len(v.messages), len(want))
	for w, i in want {
		if i >= len(v.messages) {
			break
		}
		got := message_plain_text(&v.messages[i])
		got, _ = strings.replace_all(got, "  ", " ", context.temp_allocator)
		testing.expectf(t, strings.trim_space(got) == w, "message %d: got %q, want %q", i, got, w)
	}

	// Adding a phrase hides the messages showing with it, but not our own.
	rule_add(&rules.ignored_phrases, "fine")
	rule_add(&rules.ignored_phrases, "spoiler")
	chat_view_remove_phrases(&v)
	testing.expect_value(t, len(v.messages), len(want) - 1)
}

@(test)
ignored_phrases_are_saved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	data := `{"ignored_phrases":["Spoiler","spoiler"," x->Y ",""]}`
	testing.expect(t, parse_layout(transmute([]byte)string(data), &l))
	testing.expect_value(t, strings.join(l.chat.ignored_phrases[:], ",", context.temp_allocator), "spoiler,x -> Y")
}
