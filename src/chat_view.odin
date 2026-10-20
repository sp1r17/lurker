package app

import "core:unicode/utf8"
import "core:strings"

CHAT_MAX_MESSAGES :: 1000
// Sizes in logical pixels, scaled by the display scale.
CHAT_WIDTH :: 340
CHAT_FONT_SIZE :: 14
CHAT_PADDING :: 8
CHAT_MESSAGE_GAP :: 3
CHAT_SCROLL_STEP :: 60
CHAT_MORE_BAR_HEIGHT :: 28

CHAT_BACKGROUND :: Color{0x18, 0x18, 0x1b, 255}
CHAT_TEXT :: Color{0xde, 0xde, 0xe3, 255}
CHAT_SYSTEM_TEXT :: Color{0x9a, 0x9a, 0xa3, 255}
CHAT_MORE_BAR :: Color{0x2a, 0x2a, 0x30, 235}

// The scrolling list of chat messages. `scroll` is how far the view is above the
// newest message, in pixels; 0 follows new messages as they arrive.
Chat_View :: struct {
	messages:   [dynamic]Chat_Message,
	scroll:     f32,
	// Set while drawing: the furthest the view can scroll, and where the "more
	// messages below" bar is (zero size when hidden).
	max_scroll: f32,
	more_bar:   Rect,
}

chat_view_destroy :: proc(v: ^Chat_View) {
	for m in v.messages {
		destroy_chat_message(m)
	}
	delete(v.messages)
}

// Adds messages that have just arrived. When the view is scrolled up, it's moved by
// the new messages' height so the messages being read stay put.
chat_view_add :: proc(v: ^Chat_View, r: ^Renderer, scale, width: f32, new_messages: []Chat_Message) {
	for m in new_messages {
		if v.scroll > 0 {
			v.scroll += message_height(r, m, scale, width) + CHAT_MESSAGE_GAP * scale
		}
		append(&v.messages, m)
	}
	if over := len(v.messages) - CHAT_MAX_MESSAGES; over > 0 {
		for m in v.messages[:over] {
			destroy_chat_message(m)
		}
		remove_range(&v.messages, 0, over)
	}
}

chat_view_scroll :: proc(v: ^Chat_View, wheel_y, scale: f32) {
	v.scroll = clamp(v.scroll + wheel_y * CHAT_SCROLL_STEP * scale, 0, v.max_scroll)
}

// Handles a click at (x, y) in pixels. Returns true if it changed the view.
chat_view_click :: proc(v: ^Chat_View, x, y: f32) -> bool {
	b := v.more_bar
	if b.w > 0 && x >= b.x && x < b.x + b.w && y >= b.y && y < b.y + b.h {
		v.scroll = 0
		return true
	}
	return false
}

draw_chat_view :: proc(r: ^Renderer, v: ^Chat_View, rect: Rect, scale: f32) {
	draw_rect(r, rect, CHAT_BACKGROUND)
	pad := CHAT_PADDING * scale
	gap := CHAT_MESSAGE_GAP * scale
	content_w := rect.w - 2 * pad

	clip_begin(r, rect)
	// Messages are laid out from the newest upwards; `bottom` is the next one's
	// bottom edge.
	bottom := rect.y + rect.h - pad + v.scroll
	total: f32
	all_measured := true
	for i := len(v.messages) - 1; i >= 0; i -= 1 {
		m := v.messages[i]
		h := message_height(r, m, scale, content_w)
		top := bottom - h
		if top < rect.y + rect.h {
			layout_message(r, m, scale, rect.x + pad, top, content_w, draw = true)
		}
		total += h + gap
		bottom = top - gap
		if bottom < rect.y {
			// Everything older is off screen, so the full height isn't known.
			all_measured = i == 0
			break
		}
	}
	if all_measured {
		v.max_scroll = max(0, total - (rect.h - 2 * pad))
		v.scroll = min(v.scroll, v.max_scroll)
	} else {
		v.max_scroll = max(v.max_scroll, v.scroll + rect.h)
	}

	v.more_bar = {}
	if v.scroll > 0 {
		bar_h := CHAT_MORE_BAR_HEIGHT * scale
		v.more_bar = {rect.x, rect.y + rect.h - bar_h, rect.w, bar_h}
		draw_rect(r, v.more_bar, CHAT_MORE_BAR)
		label := "More messages below"
		size := CHAT_FONT_SIZE * scale
		lw := text_width(r, .Regular, size, label)
		lh := line_height(r, .Regular, size)
		draw_text(
			r,
			.Regular,
			size,
			v.more_bar.x + (v.more_bar.w - lw) / 2,
			v.more_bar.y + (bar_h - lh) / 2,
			label,
			CHAT_TEXT,
		)
	}
	clip_end(r)
}

@(private = "file")
message_height :: proc(r: ^Renderer, m: Chat_Message, scale, width: f32) -> f32 {
	return layout_message(r, m, scale, 0, 0, width, draw = false)
}

// Word-wraps a message into `width`, drawing it if `draw` is set. Returns its height.
// "Name: text" for chat, "Name text" in the name's colour for /me, grey for system.
@(private = "file")
layout_message :: proc(r: ^Renderer, m: Chat_Message, scale, x, y, width: f32, draw: bool) -> f32 {
	pen := Pen {
		r      = r,
		size   = CHAT_FONT_SIZE * scale,
		left   = x,
		x      = x,
		y      = y,
		width  = width,
		draw   = draw,
	}
	pen.line_h = line_height(r, .Regular, pen.size)

	text_color := CHAT_TEXT
	switch m.kind {
	case .Chat:
		put_words(&pen, .Bold, m.color, m.name)
		put_text(&pen, .Bold, m.color, ":")
	case .Action:
		put_words(&pen, .Bold, m.color, m.name)
		text_color = m.color
	case .System:
		text_color = CHAT_SYSTEM_TEXT
	}
	put_words(&pen, .Regular, text_color, m.text)
	return pen.y + pen.line_h - y
}

@(private = "file")
Pen :: struct {
	r:      ^Renderer,
	size:   f32,
	left:   f32,
	x, y:   f32,
	width:  f32,
	line_h: f32,
	draw:   bool,
}

@(private = "file")
new_line :: proc(pen: ^Pen) {
	pen.x = pen.left
	pen.y += pen.line_h
}

// Puts space-separated words, wrapping between words.
@(private = "file")
put_words :: proc(pen: ^Pen, font: Font, color: Color, text: string) {
	space := text_width(pen.r, font, pen.size, " ")
	rest := text
	for word in strings.fields_iterator(&rest) {
		if pen.x > pen.left {
			pen.x += space
		}
		put_word(pen, font, color, word)
	}
}

@(private = "file")
put_word :: proc(pen: ^Pen, font: Font, color: Color, word: string) {
	w := text_width(pen.r, font, pen.size, word)
	if pen.x > pen.left && pen.x + w > pen.left + pen.width {
		new_line(pen)
	}
	if w <= pen.width {
		put_text(pen, font, color, word)
		return
	}
	// Longer than a whole line: break it between characters.
	start := 0
	for i := 0; i < len(word); {
		_, n := utf8.decode_rune_in_string(word[i:])
		if text_width(pen.r, font, pen.size, word[start:i + n]) > pen.left + pen.width - pen.x && i > start {
			put_text(pen, font, color, word[start:i])
			new_line(pen)
			start = i
		}
		i += n
	}
	put_text(pen, font, color, word[start:])
}

@(private = "file")
put_text :: proc(pen: ^Pen, font: Font, color: Color, text: string) {
	// Advancing by the measured width, not the drawn one, keeps drawing and measuring
	// wrapping identically.
	if pen.draw {
		draw_text(pen.r, font, pen.size, pen.x, pen.y, text, color)
	}
	pen.x += text_width(pen.r, font, pen.size, text)
}
