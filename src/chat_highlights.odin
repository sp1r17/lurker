package app

import "core:strings"
import "core:text/regex"

// The user's own highlights, beyond mentions of them: phrases (whole words, or a
// /regular expression/ as typed, with flags after it: /gg+/i ignores case), and
// everyone's messages from chosen people or with a chosen badge, each on a
// background in a colour of its own.

Highlight_Color :: enum {
	Red,
	Orange,
	Yellow,
	Green,
	Teal,
	Blue,
	Purple,
	Pink,
}

// Behind a message highlighted in each colour: as strong as a mention's.
@(rodata)
HIGHLIGHT_BACKGROUNDS := [Highlight_Color]Color {
	.Red    = {0xe0, 0x3c, 0x3c, 70},
	.Orange = {0xe8, 0x80, 0x1e, 70},
	.Yellow = {0xd8, 0xc0, 0x1e, 60},
	.Green  = {0x2e, 0xb0, 0x5a, 65},
	.Teal   = {0x1e, 0xb4, 0xb4, 65},
	.Blue   = {0x2e, 0x7c, 0xf0, 70},
	.Purple = {0x91, 0x47, 0xff, 70},
	.Pink   = {0xe0, 0x4c, 0xb4, 70},
}

// A swatch of each colour, for choosing it in Settings: the background at full
// strength.
highlight_swatch :: proc(c: Highlight_Color) -> Color {
	color := HIGHLIGHT_BACKGROUNDS[c]
	color.a = 255
	return color
}

// A person (their login) or a badge (its set: "vip", "subscriber") whose
// messages are highlighted, and in which colour. `name` is owned.
Highlight_Entry :: struct {
	name:  string,
	color: Highlight_Color,
}

// What people often call badges, as Twitch names their sets.
@(rodata)
BADGE_ALIASES := [?][2]string {
	{"sub", "subscriber"},
	{"subs", "subscriber"},
	{"mod", "moderator"},
	{"mods", "moderator"},
	{"streamer", "broadcaster"},
	{"prime", "premium"},
	{"artist", "artist-badge"},
	{"vips", "vip"},
}

// The badge set `typed` names ("Sub" is "subscriber"), or "" if it can't be one.
// Allocated with the temp allocator.
badge_set_name :: proc(typed: string) -> string {
	name := strings.to_lower(strings.trim_space(typed), context.temp_allocator)
	for alias in BADGE_ALIASES {
		if name == alias[0] {
			return alias[1]
		}
	}
	for c in name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return ""
		}
	}
	return name
}

// Adds `name` to `list` in the next colour along, unless it's there already.
highlight_entry_add :: proc(list: ^[dynamic]Highlight_Entry, name: string) {
	if name == "" {
		return
	}
	for e in list {
		if e.name == name {
			return
		}
	}
	color := Highlight_Color(len(list) % len(Highlight_Color))
	append(list, Highlight_Entry{strings.clone(name), color})
}

highlight_entry_remove :: proc(list: ^[dynamic]Highlight_Entry, i: int) {
	if i < 0 || i >= len(list) {
		return
	}
	delete(list[i].name)
	ordered_remove(list, i)
}

// The next colour along for entry `i`.
highlight_entry_recolor :: proc(list: ^[dynamic]Highlight_Entry, i: int) {
	if i >= 0 && i < len(list) {
		list[i].color = Highlight_Color((int(list[i].color) + 1) % len(Highlight_Color))
	}
}

highlight_entries_destroy :: proc(list: ^[dynamic]Highlight_Entry) {
	for e in list {
		delete(e.name)
	}
	delete(list^)
}

// The names in `list`, for the settings list. Allocated with the temp allocator.
highlight_entry_names :: proc(list: []Highlight_Entry) -> []string {
	names := make([]string, len(list), context.temp_allocator)
	for e, i in list {
		names[i] = e.name
	}
	return names
}

// The background for `m` from the people and badges chosen: the person's colour
// first, then the first chosen badge it carries.
custom_highlight :: proc(m: ^Chat_Message, rules: ^Chat_Rules) -> (color: Color, ok: bool) {
	if rules == nil || m.kind == .System {
		return {}, false
	}
	for e in rules.people {
		if e.name == m.login {
			return HIGHLIGHT_BACKGROUNDS[e.color], true
		}
	}
	for e in rules.badges {
		for badge in m.badges {
			set, _, _ := strings.partition(badge, "/")
			if set == e.name {
				return HIGHLIGHT_BACKGROUNDS[e.color], true
			}
		}
	}
	return {}, false
}

// Whether `phrase` is a /regular expression/ (with flags after it, if any) that
// compiles.
phrase_is_regex :: proc(phrase: string) -> bool {
	if len(phrase) < 3 || phrase[0] != '/' || strings.last_index_byte(phrase, '/') == 0 {
		return false
	}
	r, err := regex.create_by_user(phrase, context.temp_allocator)
	if err != nil {
		return false
	}
	regex.destroy(r, context.temp_allocator)
	return true
}

// How a highlight phrase is kept: a regular expression as typed, anything else
// lowercase (matched ignoring case). Allocated with the temp allocator.
normalize_phrase :: proc(typed: string) -> string {
	phrase := strings.trim_space(typed)
	if phrase_is_regex(phrase) {
		return phrase
	}
	return strings.to_lower(phrase, context.temp_allocator)
}

// A phrase made ready to match: a compiled expression, or the words as they are.
Compiled_Phrase :: struct {
	// The phrase it was made from. Owned.
	phrase:  string,
	pattern: regex.Regular_Expression,
	is_regex: bool,
}

// Keeps `rules.compiled` in step with `rules.highlights`, compiling only when
// they've changed.
@(private = "file")
compile_phrases :: proc(rules: ^Chat_Rules) {
	same := len(rules.compiled) == len(rules.highlights)
	for c, i in rules.compiled {
		if !same {
			break
		}
		same = c.phrase == rules.highlights[i]
	}
	if same {
		return
	}
	compiled_phrases_destroy(rules)
	for phrase in rules.highlights {
		c := Compiled_Phrase{phrase = strings.clone(phrase)}
		if len(phrase) >= 3 && phrase[0] == '/' {
			if r, err := regex.create_by_user(phrase); err == nil {
				c.pattern, c.is_regex = r, true
			}
		}
		append(&rules.compiled, c)
	}
}

compiled_phrases_destroy :: proc(rules: ^Chat_Rules) {
	for c in rules.compiled {
		delete(c.phrase)
		if c.is_regex {
			regex.destroy(c.pattern)
		}
	}
	clear(&rules.compiled)
}

// Whether the message's text has one of the user's highlight phrases: as whole
// words ignoring case, or matching one as a regular expression.
highlighted :: proc(m: ^Chat_Message, rules: ^Chat_Rules) -> bool {
	if rules == nil || len(rules.highlights) == 0 || m.kind == .System {
		return false
	}
	compile_phrases(rules)
	text := message_plain_text(m)
	lower := strings.to_lower(text, context.temp_allocator)
	for &c in rules.compiled {
		if c.is_regex {
			capture, found := regex.match(c.pattern, text, context.temp_allocator, context.temp_allocator)
			regex.destroy(capture, context.temp_allocator)
			if found {
				return true
			}
		} else if contains_words(lower, c.phrase) {
			return true
		}
	}
	return false
}
