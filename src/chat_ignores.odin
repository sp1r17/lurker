package app

import "core:fmt"
import "core:strings"
import "core:text/regex"
import "core:unicode/utf8"

// Ignored phrases: messages with one in them are hidden, or, written
// "phrase -> words", shown with those words in its place ("phrase ->" takes it
// out). Phrases are as highlight phrases are (chat_highlights.odin): whole words
// ignoring case, or a /regular expression/.

// Where a /regular expression/'s closing slash is past, or 0 if `s` doesn't
// start with one.
@(private = "file")
regex_end :: proc(s: string) -> int {
	if len(s) < 2 || s[0] != '/' {
		return 0
	}
	for i := 1; i < len(s); i += 1 {
		switch s[i] {
		case '\\':
			i += 1
		case '/':
			return i + 1
		}
	}
	return 0
}

// The phrase of an ignore entry, and the words to put in its place if it
// `replaces` (a "->" after the phrase, or after an expression's closing slash).
// Both point into `entry`.
split_ignore :: proc(entry: string) -> (phrase, replacement: string, replaces: bool) {
	from := regex_end(entry)
	i := strings.index(entry[from:], "->")
	if i < 0 {
		return strings.trim_space(entry), "", false
	}
	i += from
	return strings.trim_space(entry[:i]), strings.trim_space(entry[i + 2:]), true
}

// How an ignore entry is kept: its phrase as a highlight phrase is
// (normalize_phrase), then " -> " and the words, as typed. "" if there's no
// phrase. Allocated with the temp allocator.
normalize_ignore :: proc(typed: string) -> string {
	phrase, replacement, replaces := split_ignore(strings.trim_space(typed))
	phrase = normalize_phrase(phrase)
	if phrase == "" {
		return ""
	}
	if !replaces {
		return phrase
	}
	if replacement == "" {
		return fmt.tprintf("%s ->", phrase)
	}
	return fmt.tprintf("%s -> %s", phrase, replacement)
}

// Whether the message has a phrase that hides it.
ignored_by_phrase :: proc(m: ^Chat_Message, rules: ^Chat_Rules) -> bool {
	if rules == nil || len(rules.ignored_phrases) == 0 || m.kind == .System {
		return false
	}
	compile_phrases(&rules.compiled_ignores, rules.ignored_phrases[:], ignores = true)
	text := message_plain_text(m)
	lower := strings.to_lower(text, context.temp_allocator)
	for &c in rules.compiled_ignores {
		if !c.replaces && phrase_matches(&c, text, lower) {
			return true
		}
	}
	return false
}

// Puts each replacing phrase's words in its place in the message's text, before
// emotes are looked for in it: a replacement can be an emote's name.
apply_replacements :: proc(m: ^Chat_Message, rules: ^Chat_Rules) {
	if rules == nil || len(rules.ignored_phrases) == 0 || m.kind == .System {
		return
	}
	compile_phrases(&rules.compiled_ignores, rules.ignored_phrases[:], ignores = true)
	for &f in m.fragments {
		if f.kind != .Text {
			continue
		}
		text := f.text
		for &c in rules.compiled_ignores {
			if c.replaces {
				text = replace_phrase(&c, text)
			}
		}
		if text != f.text {
			delete(f.text)
			f.text = strings.clone(text)
		}
	}
}

// `text` with the phrase replaced everywhere it is, or `text` itself if it
// isn't there. Allocated with the temp allocator.
@(private = "file")
replace_phrase :: proc(c: ^Compiled_Phrase, text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	last := 0
	if c.is_regex {
		// Matched from each place on: an expression anchored to the start can
		// only match once.
		anchored := len(c.phrase) > 1 && c.phrase[1] == '^'
		for at := 0; at <= len(text); {
			capture, found := regex.match(c.pattern, text[at:], context.temp_allocator, context.temp_allocator)
			if !found || len(capture.pos) == 0 {
				break
			}
			start, end := at + capture.pos[0][0], at + capture.pos[0][1]
			if start == end {
				// Matching nothing replaces nothing: look on from the next letter.
				if start >= len(text) {
					break
				}
				_, size := utf8.decode_rune_in_string(text[start:])
				at = start + size
				continue
			}
			strings.write_string(&sb, text[last:start])
			strings.write_string(&sb, c.replacement)
			last, at = end, end
			if anchored {
				break
			}
		}
	} else {
		// Found in lowercase, so where the case changes the length (rarely, outside
		// English), the places wouldn't line up: left as it is.
		lower := strings.to_lower(text, context.temp_allocator)
		if len(lower) != len(text) {
			return text
		}
		for {
			i := find_words(lower, c.phrase, last)
			if i < 0 {
				break
			}
			strings.write_string(&sb, text[last:i])
			strings.write_string(&sb, c.replacement)
			last = i + len(c.phrase)
		}
	}
	if last == 0 {
		return text
	}
	strings.write_string(&sb, text[last:])
	return strings.to_string(sb)
}

// Drops messages with a phrase that hides them, when one has just been added,
// leaving your own: the rest move up over them, in order.
chat_view_remove_phrases :: proc(v: ^Chat_View) {
	kept := 0
	for i in 0 ..< len(v.messages) {
		m := &v.messages[i]
		if !m.own && ignored_by_phrase(m, v.rules) {
			destroy_chat_message(m^)
			continue
		}
		v.messages[kept] = m^
		kept += 1
	}
	resize(&v.messages, kept)
	v.selection = {}
}
