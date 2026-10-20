package app

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Twitch drops chat messages longer than this.
MAX_MESSAGE_BYTES :: 500

// A one-line text field: the chat box. `cursor` is a byte index into `text`, always
// on a character boundary.
Text_Input :: struct {
	text:       [dynamic]u8,
	cursor:     int,
	focused:    bool,
	completion: Completion,
}

// Tab completion in progress: Tab again cycles through the candidates.
Completion :: struct {
	active:     bool,
	// The completed word's start, and the end of what's been put there.
	start, end: int,
	// Owned.
	candidates: [dynamic]string,
	index:      int,
}

input_destroy :: proc(ti: ^Text_Input) {
	delete(ti.text)
	reset_completion(ti)
	delete(ti.completion.candidates)
}

input_text :: proc(ti: ^Text_Input) -> string {
	return string(ti.text[:])
}

input_clear :: proc(ti: ^Text_Input) {
	clear(&ti.text)
	ti.cursor = 0
	reset_completion(ti)
}

// Inserts at the cursor, up to Twitch's message length.
input_insert :: proc(ti: ^Text_Input, s: string) {
	reset_completion(ti)
	room := MAX_MESSAGE_BYTES - len(ti.text)
	s := s
	if len(s) > room {
		// Cut on a character boundary.
		cut := room
		for cut > 0 && !utf8.rune_start(s[cut]) {
			cut -= 1
		}
		s = s[:cut]
	}
	inject_at(&ti.text, ti.cursor, s)
	ti.cursor += len(s)
}

Input_Move :: enum {
	Char,
	Word,
	Line,
}

// Deletes back from the cursor (Backspace), or forward (Delete) if `forward`.
input_delete :: proc(ti: ^Text_Input, by: Input_Move, forward := false) {
	reset_completion(ti)
	other := step(ti, by, forward)
	lo, hi := min(other, ti.cursor), max(other, ti.cursor)
	remove_range(&ti.text, lo, hi)
	ti.cursor = lo
}

input_move :: proc(ti: ^Text_Input, by: Input_Move, forward: bool) {
	reset_completion(ti)
	ti.cursor = step(ti, by, forward)
}

// Where the cursor would go: one character, to the next word edge, or to the end.
@(private = "file")
step :: proc(ti: ^Text_Input, by: Input_Move, forward: bool) -> int {
	text := input_text(ti)
	i := ti.cursor
	switch by {
	case .Line:
		return len(text) if forward else 0
	case .Char:
		return next_char(text, i) if forward else prev_char(text, i)
	case .Word:
		// Skip spaces, then the word, like most editors.
		if forward {
			for i < len(text) && text[i] == ' ' {
				i = next_char(text, i)
			}
			for i < len(text) && text[i] != ' ' {
				i = next_char(text, i)
			}
		} else {
			for i > 0 && text[i - 1] == ' ' {
				i = prev_char(text, i)
			}
			for i > 0 && text[i - 1] != ' ' {
				i = prev_char(text, i)
			}
		}
		return i
	}
	return i
}

@(private = "file")
next_char :: proc(text: string, i: int) -> int {
	if i >= len(text) {
		return len(text)
	}
	_, n := utf8.decode_rune_in_string(text[i:])
	return i + n
}

@(private = "file")
prev_char :: proc(text: string, i: int) -> int {
	i := i
	for i > 0 {
		i -= 1
		if utf8.rune_start(text[i]) {
			break
		}
	}
	return i
}

@(private = "file")
reset_completion :: proc(ti: ^Text_Input) {
	c := &ti.completion
	for s in c.candidates {
		delete(s)
	}
	clear(&c.candidates)
	c.active = false
}

// Tab completion, as in Chatterino: completes the word before the cursor from
// `emote_names` and `user_names`, case-insensitively; Tab again cycles (backwards if
// `backwards`). A word starting with "@" completes user names only, keeping the @.
input_complete :: proc(ti: ^Text_Input, emote_names, user_names: []string, backwards := false) {
	c := &ti.completion
	if !c.active {
		text := input_text(ti)
		start := ti.cursor
		for start > 0 && text[start - 1] != ' ' {
			start -= 1
		}
		word := text[start:ti.cursor]
		at := strings.has_prefix(word, "@")
		prefix := strings.to_lower(word[1:] if at else word, context.temp_allocator)
		if prefix == "" {
			return
		}

		found := make([dynamic]string, context.temp_allocator)
		if !at {
			for name in emote_names {
				if strings.has_prefix(strings.to_lower(name, context.temp_allocator), prefix) {
					append(&found, name)
				}
			}
		}
		for name in user_names {
			if strings.has_prefix(strings.to_lower(name, context.temp_allocator), prefix) {
				append(&found, strings.concatenate({"@", name}, context.temp_allocator) if at else name)
			}
		}
		if len(found) == 0 {
			return
		}
		slice.sort_by(found[:], proc(a, b: string) -> bool {
			return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)
		})
		for name, i in found {
			if i == 0 || name != found[i - 1] {
				append(&c.candidates, strings.clone(name))
			}
		}
		c.active = true
		c.start = start
		c.end = ti.cursor
		c.index = -1 if !backwards else 0
	}

	n := len(c.candidates)
	c.index = (c.index + (n - 1 if backwards else 1)) % n
	// Replace what's there with the candidate and a space.
	replacement := strings.concatenate({c.candidates[c.index], " "}, context.temp_allocator)
	remove_range(&ti.text, c.start, c.end)
	inject_at(&ti.text, c.start, replacement)
	c.end = c.start + len(replacement)
	ti.cursor = c.end
}
