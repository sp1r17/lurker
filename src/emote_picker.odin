package app

import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

// How many emotes the picker lists at once.
PICKER_ROWS :: 6
PICKER_BACKGROUND :: Color{0x0e, 0x0e, 0x10, 255}
// Short, to leave the names room in a narrow chat.
PICKER_SOURCE_LABELS := [Emote_Source]string {
	.Channel_7TV  = "7TV",
	.Channel_BTTV = "BTTV",
	.Channel_FFZ  = "FFZ",
	.Global_7TV   = "7TV global",
	.Global_BTTV  = "BTTV global",
	.Global_FFZ   = "FFZ global",
}

// Typing ":" and the start of an emote's name in the chat box lists the emotes it
// could be, as on twitch.tv and in Chatterino; Tab, Enter or a click puts one in.
Picker_Match :: struct {
	// Point into the Emotes they're from, valid until those change.
	name:   string,
	emote:  Emote,
	source: Emote_Source,
}

// The channel's and global emotes whose names start with `query`, then those
// that contain it elsewhere, ignoring case; shorter names first, so the closest
// match leads. Where the channel and global sets share a name, the one chat
// shows wins. Allocated with the temp allocator.
emote_picker_matches :: proc(channel, global: ^Emotes, query: string) -> []Picker_Match {
	lower_query := strings.to_lower(query, context.temp_allocator)
	Ranked :: struct {
		match:  Picker_Match,
		prefix: bool,
	}
	found := make([dynamic]Ranked, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for e in ([]^Emotes{channel, global}) {
		if e == nil {
			continue
		}
		for &set, source in e.sets {
			for name, emote in set {
				if name in seen {
					continue
				}
				seen[name] = true
				lower := strings.to_lower(name, context.temp_allocator)
				at := strings.index(lower, lower_query)
				if at < 0 {
					continue
				}
				append(&found, Ranked{{name, emote, source}, at == 0})
			}
		}
	}
	slice.sort_by(found[:], proc(a, b: Ranked) -> bool {
		if a.prefix != b.prefix {
			return a.prefix
		}
		if len(a.match.name) != len(b.match.name) {
			return len(a.match.name) < len(b.match.name)
		}
		return a.match.name < b.match.name
	})
	matches := make([]Picker_Match, min(len(found), PICKER_ROWS), context.temp_allocator)
	for &m, i in matches {
		m = found[i].match
	}
	return matches
}

// What the picker is for: the word before the cursor in `p`'s chat box, if it's
// ":" and at least two more characters, without the ":", and where it starts.
@(private = "file")
picker_query :: proc(p: ^Chat_Pane) -> (query: string, start: int, ok: bool) {
	ti := &p.boxes[.Chat]
	if !ti.focused || p.channel == "" {
		return "", 0, false
	}
	text := input_text(ti)
	start = ti.cursor
	for start > 0 && text[start - 1] != ' ' {
		start -= 1
	}
	word := text[start:ti.cursor]
	if !strings.has_prefix(word, ":") || len(word) < 3 || p.picker_dismissed == start + 1 {
		return "", 0, false
	}
	return word[1:], start, true
}

// The picker's emotes for `p`, or none if it isn't open.
@(private = "file")
picker_list :: proc(app: ^App, p: ^Chat_Pane) -> (matches: []Picker_Match, start: int) {
	query, at, open := picker_query(p)
	if !open {
		return nil, 0
	}
	return emote_picker_matches(&p.emotes, &app.assets.emotes, query), at
}

// Puts match `i` in place of the ":word" being typed.
@(private = "file")
picker_accept :: proc(app: ^App, p: ^Chat_Pane, i: int) {
	matches, start := picker_list(app, p)
	if i < 0 || i >= len(matches) {
		return
	}
	ti := &p.boxes[.Chat]
	ti.anchor = start
	input_insert(ti, strings.concatenate({matches[i].name, " "}, context.temp_allocator))
	p.picker_selected = 0
}

// Keys while the picker is open: Up and Down choose, Tab and Enter put the emote
// in, Esc closes it. Returns true if the key was the picker's.
emote_picker_key :: proc(app: ^App, p: ^Chat_Pane, key: sdl.KeyboardEvent) -> bool {
	matches, start := picker_list(app, p)
	n := len(matches)
	if n == 0 {
		return false
	}
	switch key.key {
	case sdl.K_UP:
		p.picker_selected = (p.picker_selected + n - 1) % n
	case sdl.K_DOWN:
		p.picker_selected = (p.picker_selected + 1) % n
	case sdl.K_TAB, sdl.K_RETURN, sdl.K_KP_ENTER:
		picker_accept(app, p, min(p.picker_selected, n - 1))
	case sdl.K_ESCAPE:
		// Closed for this word; typing another opens it again.
		p.picker_dismissed = start + 1
	case:
		return false
	}
	return true
}

// A click on the picker. Returns true if it hit a row.
emote_picker_click :: proc(app: ^App, p: ^Chat_Pane, x, y: f32) -> bool {
	for row, i in p.picker_rows {
		if in_rect(row, x, y) {
			picker_accept(app, p, i)
			return true
		}
	}
	return false
}

// The picker, just above the chat box: each emote, its name, and where it's from.
draw_emote_picker :: proc(app: ^App, p: ^Chat_Pane) {
	clear(&p.picker_rows)
	if _, _, open := picker_query(p); !open {
		// Esc closed it for one word only.
		p.picker_dismissed = 0
	}
	matches, _ := picker_list(app, p)
	if len(matches) == 0 {
		return
	}
	a := &app.assets
	r := &a.renderer
	scale := app.scale
	size := CHAT_FONT_SIZE * scale
	pad := CHAT_PADDING * scale
	lh := line_height(r, .Regular, size)
	emote_h := EMOTE_HEIGHT * scale * r.text_scale
	row_h := max(emote_h, lh) + pad
	p.picker_selected = min(p.picker_selected, len(matches) - 1)

	box := p.input_rect
	panel := Rect{box.x, box.y - 4 * scale - f32(len(matches)) * row_h - pad, box.w, f32(len(matches)) * row_h + pad}
	draw_rect(r, panel, PICKER_BACKGROUND)
	pixel_scale: f32 = 2 if scale * r.text_scale > 1 else 1
	for m, i in matches {
		row := Rect{panel.x, panel.y + pad / 2 + f32(i) * row_h, panel.w, row_h}
		append(&p.picker_rows, row)
		switch {
		case i == p.picker_selected:
			draw_rect(r, row, MENU_HOVER)
		case in_rect(row, app.mouse.x, app.mouse.y):
			draw_rect(r, row, BROWSE_CARD_HOVER)
		}
		url := m.emote.url_2x if pixel_scale > 1 && m.emote.url_2x != "" else m.emote.url_1x
		image := image_get(&a.images, &a.jobs, url, pixel_scale)
		image_w := emote_h
		if image.state == .Ready && image.size.y > 0 {
			image_w = emote_h * image.size.x / image.size.y
			texture, next := image_frame(image, a.now_ms)
			draw_image(r, texture, {row.x + pad, row.y + (row.h - emote_h) / 2, image_w, emote_h})
			if next >= 0 && (a.next_frame_ms < 0 || next < a.next_frame_ms) {
				a.next_frame_ms = next
			}
		}
		tx := row.x + pad + max(image_w, emote_h) + pad
		ty := row.y + (row.h - lh) / 2
		room := row.x + row.w - pad - tx
		// Where it's from, at the right, if the name still fits beside it.
		label := PICKER_SOURCE_LABELS[m.source]
		label_w := text_width(r, .Regular, size, label) + pad
		if text_width(r, .Bold, size, m.name) <= room - label_w {
			draw_text(r, .Regular, size, row.x + row.w - pad - label_w + pad, ty, label, CHAT_SYSTEM_TEXT)
		}
		draw_text(r, .Bold, size, tx, ty, fit_text(r, .Bold, size, m.name, room), CHAT_TEXT)
	}
}
