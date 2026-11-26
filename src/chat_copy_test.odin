package app

import "core:testing"

// A message laid out from `words`: each a Text item 10 px wide per byte, with a
// 5 px space between, on one line; "" for a badge image.
@(private = "file")
laid_out :: proc(words: ..string) -> Chat_Message {
	m: Chat_Message
	x: f32 = 0
	for w in words {
		if w == "" {
			append(&m.layout.items, Layout_Item{kind = .Image, hint = .Badge, text = "moderator/1", rect = {x, 0, 18, 18}})
			x += 18
		} else {
			append(&m.layout.items, Layout_Item{kind = .Text, text = w, rect = {x, 0, f32(len(w)) * 10, 18}})
			x += f32(len(w)) * 10
		}
		x += 5
	}
	return m
}

@(private = "file")
free_view :: proc(v: ^Chat_View) {
	for m in v.messages {
		delete(m.layout.items)
	}
	delete(v.messages)
}

@(test)
selection_copies_what_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v: Chat_View
	defer free_view(&v)
	append(&v.messages, laid_out("", "Alice:", "hello", "there"), laid_out("Bob:", "general", "kenobi"))
	// From inside "hello" to inside "general", whichever way it was dragged.
	v.selection = {shown = true, anchor = {0, 2, 2}, focus = {1, 1, 3}}
	testing.expect_value(t, chat_selection_text(&v), "llo there\nBob: gen")
	v.selection.anchor, v.selection.focus = v.selection.focus, v.selection.anchor
	testing.expect_value(t, chat_selection_text(&v), "llo there\nBob: gen")
	// The badge is left out, the name kept.
	v.selection = {shown = true, anchor = {0, 0, 0}, focus = {0, 2, 5}}
	testing.expect_value(t, chat_selection_text(&v), "Alice: hello")
}

@(test)
selection_follows_its_messages :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v: Chat_View
	defer free_view(&v)
	v.selection = {shown = true, anchor = {5, 0, 0}, focus = {7, 1, 2}}
	chat_selection_shift(&v, 3)
	testing.expect_value(t, v.selection.anchor.message, 8)
	testing.expect_value(t, v.selection.focus.message, 10)
	// Trimming away its first message drops it.
	chat_selection_shift(&v, -9)
	testing.expect(t, !v.selection.shown)
}

@(test)
selected_part_covers_the_range :: proc(t: ^testing.T) {
	v: Chat_View
	v.selection = {shown = true, anchor = {0, 1, 2}, focus = {2, 0, 3}}
	from, to, ok := selected_part(&v, 0, 1, 5)
	testing.expect(t, ok && from == 2 && to == 5)
	_, _, ok = selected_part(&v, 0, 0, 5)
	testing.expect(t, !ok)
	from, to, ok = selected_part(&v, 1, 4, 6)
	testing.expect(t, ok && from == 0 && to == 6)
	from, to, ok = selected_part(&v, 2, 0, 8)
	testing.expect(t, ok && from == 0 && to == 3)
	_, _, ok = selected_part(&v, 2, 1, 8)
	testing.expect(t, !ok)
	// Past the end of a word that got shorter (laid out again): clamped.
	from, to, ok = selected_part(&v, 2, 0, 2)
	testing.expect(t, ok && from == 0 && to == 2)
}
