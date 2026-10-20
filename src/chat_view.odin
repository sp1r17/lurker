package app

import "core:strings"
import "core:unicode/utf8"

CHAT_MAX_MESSAGES :: 1000
// Sizes in logical pixels, scaled by the display scale.
CHAT_WIDTH :: 340
CHAT_FONT_SIZE :: 17
CHAT_PADDING :: 8
// Room for emotes to stick out of their message (EMOTE_OVERHANG) without
// touching the next one.
CHAT_MESSAGE_GAP :: 6
CHAT_SCROLL_STEP :: 60
CHAT_MORE_BAR_HEIGHT :: 28
// Emotes and badges are scaled to these heights, keeping their shape, so emotes
// from different providers (Twitch 28 px, 7TV 32 px, some taller) line up.
EMOTE_HEIGHT :: 28
BADGE_HEIGHT :: 18
// How far an emote may stick out above and below its line, as on twitch.tv, so
// lines with emotes are barely taller than lines of text.
EMOTE_OVERHANG :: 3
BADGE_GAP :: 3

CHAT_BACKGROUND :: Color{0x18, 0x18, 0x1b, 255}
CHAT_TEXT :: Color{0xde, 0xde, 0xe3, 255}
CHAT_SYSTEM_TEXT :: Color{0x9a, 0x9a, 0xa3, 255}
CHAT_MORE_BAR :: Color{0x2a, 0x2a, 0x30, 235}

// What the chat view draws with.
Assets :: struct {
	renderer:      Renderer,
	images:        Images,
	jobs:          Jobs,
	emotes:        Emotes,
	// Milliseconds since startup, for animations.
	now_ms:        int,
	// Set while drawing: ms until an animated image on screen changes frame, or -1.
	next_frame_ms: int,
}

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

// Adds messages that have just arrived, taking ownership. When the view is scrolled
// up, it moves by the new messages' height so the messages being read stay put.
chat_view_add :: proc(v: ^Chat_View, a: ^Assets, scale, width: f32, new_messages: []Chat_Message) {
	for m in new_messages {
		append(&v.messages, m)
		added := &v.messages[len(v.messages) - 1]
		apply_third_party_emotes(added, &a.emotes)
		if v.scroll > 0 {
			v.scroll += message_layout(a, added, scale, width).height + CHAT_MESSAGE_GAP * scale
		}
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
	if v.more_bar.w > 0 && in_rect(v.more_bar, x, y) {
		v.scroll = 0
		return true
	}
	return false
}

draw_chat_view :: proc(a: ^Assets, v: ^Chat_View, rect: Rect, scale: f32) {
	r := &a.renderer
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
		layout := message_layout(a, &v.messages[i], scale, content_w)
		top := bottom - layout.height
		if top < rect.y + rect.h {
			draw_message(a, layout, rect.x + pad, top)
		}
		total += layout.height + gap
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
		draw_text(r, .Regular, size, v.more_bar.x + (v.more_bar.w - lw) / 2, v.more_bar.y + (bar_h - lh) / 2, label, CHAT_TEXT)
	}
	clip_end(r)
}

@(private = "file")
draw_message :: proc(a: ^Assets, layout: ^Message_Layout, x, y: f32) {
	size := CHAT_FONT_SIZE * layout.scale
	for item in layout.items {
		rect := Rect{x + item.rect.x, y + item.rect.y, item.rect.w, item.rect.h}
		switch item.kind {
		case .Text:
			draw_text(&a.renderer, item.font, size, rect.x, rect.y, item.text, item.color)
		case .Image:
			if item.image.state != .Ready {
				continue
			}
			texture, next := image_frame(item.image, a.now_ms)
			draw_image(&a.renderer, texture, rect)
			if next >= 0 && (a.next_frame_ms < 0 || next < a.next_frame_ms) {
				a.next_frame_ms = next
			}
		}
	}
}

Layout_Item_Kind :: enum {
	Text,
	Image,
}

// A word or image placed relative to the message's top left, in pixels.
Layout_Item :: struct {
	kind:  Layout_Item_Kind,
	rect:  Rect,
	font:  Font,
	color: Color,
	// Points into the message's own strings.
	text:  string,
	image: ^Image,
}

// A message laid out for one width and scale. Images that finish loading can change
// sizes, so it's also redone whenever Images.version moves on.
Message_Layout :: struct {
	width:          f32,
	scale:          f32,
	images_version: int,
	height:         f32,
	items:          [dynamic]Layout_Item,
}

// Lays the message out, unless its cached layout still fits.
// "Badges Name: text" for chat, "Badges Name text" in the name's colour for /me,
// grey text for system messages.
message_layout :: proc(a: ^Assets, m: ^Chat_Message, scale, width: f32) -> ^Message_Layout {
	l := &m.layout
	if l.height > 0 && l.width == width && l.scale == scale && l.images_version == a.images.version {
		return l
	}
	clear(&l.items)
	l.width = width
	l.scale = scale
	l.images_version = a.images.version

	b := Builder {
		a     = a,
		l     = l,
		scale = scale,
		size  = CHAT_FONT_SIZE * scale,
		width = width,
	}
	b.text_h = line_height(&a.renderer, .Regular, b.size)
	b.line_h = b.text_h
	pixel_scale: f32 = 2 if scale > 1 else 1

	for key in m.badges {
		badge, found := badge_lookup(&a.emotes, key)
		if !found {
			continue
		}
		image := image_get(&a.images, &a.jobs, badge.url_2x if pixel_scale > 1 && badge.url_2x != "" else badge.url_1x, pixel_scale)
		if image.state == .Failed {
			continue
		}
		put_image(&b, image, BADGE_HEIGHT, 0)
		b.x += BADGE_GAP * scale
	}

	text_color := CHAT_TEXT
	switch m.kind {
	case .Chat:
		put_words(&b, .Bold, m.color, m.name)
		put_text(&b, .Bold, m.color, ":")
	case .Action:
		put_words(&b, .Bold, m.color, m.name)
		text_color = m.color
	case .System:
		text_color = CHAT_SYSTEM_TEXT
	}

	for f in m.fragments {
		switch f.kind {
		case .Text:
			put_words(&b, .Regular, text_color, f.text)
		case .Emote:
			image := image_get(&a.images, &a.jobs, f.url_2x if pixel_scale > 1 && f.url_2x != "" else f.url_1x, pixel_scale)
			if image.state == .Failed {
				put_words(&b, .Regular, text_color, f.text)
			} else if f.zero_width && overlay_last(&b, image) {
				// Drawn over the previous emote.
			} else {
				space(&b, .Regular)
				put_image(&b, image, EMOTE_HEIGHT, EMOTE_OVERHANG)
			}
		}
	}
	end_line(&b)
	l.height = b.line_y
	return l
}

@(private = "file")
Builder :: struct {
	a:          ^Assets,
	l:          ^Message_Layout,
	scale:      f32,
	size:       f32,
	width:      f32,
	text_h:     f32,
	// The pen, and the current line's top, height and first item.
	x:          f32,
	line_y:     f32,
	line_h:     f32,
	line_start: int,
}

// Finishes the current line: centres its items vertically on the tallest one.
@(private = "file")
end_line :: proc(b: ^Builder) {
	for &item in b.l.items[b.line_start:] {
		item.rect.y = b.line_y + (b.line_h - item.rect.h) / 2
	}
	b.line_y += b.line_h
	b.line_h = b.text_h
	b.x = 0
	b.line_start = len(b.l.items)
}

// Appends an item `w` by `h`, wrapping first if it doesn't fit (unless it's first
// on its line). It sticks out `overhang` above and below the line instead of making
// the line that much taller.
@(private = "file")
place :: proc(b: ^Builder, item: Layout_Item, w, h: f32, overhang: f32 = 0) {
	if b.x > 0 && b.x + w > b.width {
		end_line(b)
	}
	placed := item
	placed.rect = {b.x, 0, w, h}
	append(&b.l.items, placed)
	b.x += w
	b.line_h = max(b.line_h, h - 2 * overhang)
}

@(private = "file")
space :: proc(b: ^Builder, font: Font) {
	if b.x > 0 {
		b.x += text_width(&b.a.renderer, font, b.size, " ")
	}
}

// Logical height in, pixel size out: `height` tall, as wide as the image's shape
// allows (square until it has loaded).
@(private = "file")
image_size :: proc(b: ^Builder, image: ^Image, height: f32) -> [2]f32 {
	aspect: f32 = 1
	if image.state == .Ready && image.size.y > 0 {
		aspect = image.size.x / image.size.y
	}
	return {height * aspect, height} * b.scale
}

@(private = "file")
put_image :: proc(b: ^Builder, image: ^Image, height, overhang: f32) {
	size := image_size(b, image, height)
	place(b, {kind = .Image, image = image}, size.x, size.y, overhang * b.scale)
}

// Puts a zero-width emote over the previous emote on the line. False if there isn't one.
@(private = "file")
overlay_last :: proc(b: ^Builder, image: ^Image) -> bool {
	if len(b.l.items) == b.line_start {
		return false
	}
	last := b.l.items[len(b.l.items) - 1]
	if last.kind != .Image {
		return false
	}
	size := image_size(b, image, EMOTE_HEIGHT)
	append(
		&b.l.items,
		Layout_Item{kind = .Image, image = image, rect = {last.rect.x + (last.rect.w - size.x) / 2, 0, size.x, size.y}},
	)
	b.line_h = max(b.line_h, size.y - 2 * EMOTE_OVERHANG * b.scale)
	return true
}

// Puts space-separated words, wrapping between words.
@(private = "file")
put_words :: proc(b: ^Builder, font: Font, color: Color, text: string) {
	rest := text
	for word in strings.fields_iterator(&rest) {
		space(b, font)
		put_word(b, font, color, word)
	}
}

@(private = "file")
put_word :: proc(b: ^Builder, font: Font, color: Color, word: string) {
	r := &b.a.renderer
	w := text_width(r, font, b.size, word)
	if w <= b.width {
		put_text(b, font, color, word)
		return
	}
	// Longer than a whole line: break it between characters.
	if b.x > 0 {
		end_line(b)
	}
	start := 0
	for i := 0; i < len(word); {
		_, n := utf8.decode_rune_in_string(word[i:])
		if i > start && text_width(r, font, b.size, word[start:i + n]) > b.width {
			put_text(b, font, color, word[start:i])
			end_line(b)
			start = i
		}
		i += n
	}
	put_text(b, font, color, word[start:])
}

@(private = "file")
put_text :: proc(b: ^Builder, font: Font, color: Color, text: string) {
	w := text_width(&b.a.renderer, font, b.size, text)
	place(b, {kind = .Text, font = font, color = color, text = text}, w, b.text_h)
}
