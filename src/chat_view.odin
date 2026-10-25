package app

import "core:slice"
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
// Emoji are sized to sit in a line of text.
EMOJI_HEIGHT :: 21
// How far an emote may stick out above and below its line, as on twitch.tv, so
// lines with emotes are barely taller than lines of text.
EMOTE_OVERHANG :: 3
BADGE_GAP :: 3

CHAT_BACKGROUND :: Color{0x18, 0x18, 0x1b, 255}
CHAT_TEXT :: Color{0xde, 0xde, 0xe3, 255}
CHAT_SYSTEM_TEXT :: Color{0x9a, 0x9a, 0xa3, 255}
CHAT_MORE_BAR :: Color{0x2a, 0x2a, 0x30, 235}
// Chatterino's colour for messages that mention you.
CHAT_MENTION_BACKGROUND :: Color{0x7f, 0x3f, 0x49, 110}
CHAT_LINK :: Color{0x8c, 0xb4, 0xff, 255}
// Backgrounds for messages Twitch marks out (Message_Accent).
@(rodata)
CHAT_ACCENT_BACKGROUNDS := [Message_Accent]Color {
	.None  = {},
	.First = {0x2e, 0x9d, 0x5f, 60},
	.Cheer = {0x91, 0x47, 0xff, 60},
	.Paid  = {0xd8, 0x8a, 0x0e, 70},
}
// How opaque messages removed by a moderator, and ones from before joining, are drawn.
CHAT_DELETED_ALPHA :: 90
CHAT_HISTORICAL_ALPHA :: 170

// What the chat view draws with.
Assets :: struct {
	renderer:      Renderer,
	images:        Images,
	jobs:          Jobs,
	emotes:        Emotes,
	// The signed-in user's Twitch emotes.
	user_emotes:   User_Emotes,
	emoji:         Emoji_Table,
	// Milliseconds since startup, for animations.
	now_ms:        int,
	// Set while drawing: ms until an animated image on screen changes frame, or -1.
	next_frame_ms: int,
}

// The user's own chat rules, kept in layout.json: phrases that highlight a message,
// and people whose messages are hidden. Lowercase and owned.
Chat_Rules :: struct {
	highlights: [dynamic]string,
	ignored:    [dynamic]string,
}

chat_rules_destroy :: proc(r: ^Chat_Rules) {
	for s in r.highlights {
		delete(s)
	}
	delete(r.highlights)
	for s in r.ignored {
		delete(s)
	}
	delete(r.ignored)
}

// The scrolling list of chat messages. `scroll` is how far the view is above the
// newest message, in pixels; 0 follows new messages as they arrive.
Chat_View :: struct {
	messages:   [dynamic]Chat_Message,
	// The channel's own emotes and badges (owned by the pane), or nil.
	emotes:     ^Emotes,
	// The user's highlights and ignores (owned by the app), or nil.
	rules:      ^Chat_Rules,
	scroll:     f32,
	// Set while drawing: the furthest the view can scroll, where the "more
	// messages below" bar is (zero size when hidden), and where names are.
	max_scroll: f32,
	more_bar:   Rect,
	name_hits:  [dynamic]Name_Hit,
	// Badges and emotes on screen, for their tooltips, and where each message is
	// (an index into `messages`), for replying to it.
	image_hits:   [dynamic]Image_Hit,
	message_hits: [dynamic]Message_Hit,
	link_hits:    [dynamic]Link_Hit,
	reply_hits:   [dynamic]Rect,
	// How many messages matched the filter.
	matches:    int,
}

Name_Hit :: struct {
	rect:  Rect,
	// Points into the message, valid until the next draw.
	login: string,
}

Image_Hit :: struct {
	rect: Rect,
	item: Layout_Item,
}

Message_Hit :: struct {
	rect:  Rect,
	index: int,
}

Link_Hit :: struct {
	rect: Rect,
	// The link as written (see chat_link), valid until the next draw.
	link: string,
}

chat_view_destroy :: proc(v: ^Chat_View) {
	for m in v.messages {
		destroy_chat_message(m)
	}
	delete(v.messages)
	delete(v.name_hits)
	delete(v.image_hits)
	delete(v.message_hits)
	delete(v.link_hits)
	delete(v.reply_hits)
}

// Adds messages that have just arrived, taking ownership. Moderation messages fade
// what they remove; messages mentioning `self_login`, or a highlight phrase, are
// highlighted, and ignored people's are dropped. When the view
// is scrolled up, it moves by the new messages' height so the messages being read
// stay put. Returns how many of them mention `self_login`.
chat_view_add :: proc(v: ^Chat_View, a: ^Assets, scale, width: f32, new_messages: []Chat_Message, self_login := "") -> (mentions_added: int) {
	for m in new_messages {
		if v.rules != nil && m.kind != .System && slice.contains(v.rules.ignored[:], m.login) {
			destroy_chat_message(m)
			continue
		}
		if m.clear != .None {
			apply_clear(v, m)
			// A deleted message leaves no line of its own.
			if len(m.fragments) == 0 {
				destroy_chat_message(m)
				continue
			}
		}
		append(&v.messages, m)
		added := &v.messages[len(v.messages) - 1]
		// Our own messages are the only ones without an ID.
		own := added.id == "" && added.kind != .System && self_login != "" && added.login == self_login
		apply_third_party_emotes(added, v.emotes, &a.emotes, &a.user_emotes if own else nil)
		apply_emoji(added, &a.emoji)
		mine := self_login != "" && added.login == self_login
		added.mention = mentions(added, self_login) || (!mine && highlighted(added, v.rules))
		if added.mention {
			mentions_added += 1
		}
		if v.scroll > 0 {
			v.scroll += message_layout(a, v.emotes, added, scale, width).height + CHAT_MESSAGE_GAP * scale
		}
	}
	trim_messages(v)
	return
}

// Adds messages from before the chat joined, taking ownership. They go before the
// messages already there, leaving out any of those (by ID), and don't count as new
// mentions.
chat_view_prepend :: proc(v: ^Chat_View, a: ^Assets, scale, width: f32, older: []Chat_Message, self_login := "") {
	shown := make(map[string]bool, allocator = context.temp_allocator)
	for m in v.messages {
		if m.id != "" {
			shown[m.id] = true
		}
	}
	keep := make([dynamic]Chat_Message, context.temp_allocator)
	for m in older {
		if m.id != "" && m.id in shown {
			destroy_chat_message(m)
		} else {
			append(&keep, m)
		}
	}
	newer := v.messages
	defer delete(newer)
	v.messages = make([dynamic]Chat_Message, 0, len(keep) + len(newer))
	// Measured from the newest message, so older ones don't move the view.
	scroll := v.scroll
	v.scroll = 0
	chat_view_add(v, a, scale, width, keep[:], self_login)
	v.scroll = scroll
	append(&v.messages, ..newer[:])
	trim_messages(v)
}

// Looks for third-party emotes again in every message, after a set of them loaded:
// messages that arrived first were shown without.
chat_view_refresh_emotes :: proc(v: ^Chat_View, a: ^Assets) {
	for &m in v.messages {
		apply_third_party_emotes(&m, v.emotes, &a.emotes)
		m.layout.height = 0
	}
}

// Drops `login`'s messages, when they've just been ignored.
chat_view_remove_user :: proc(v: ^Chat_View, login: string) {
	for i := len(v.messages) - 1; i >= 0; i -= 1 {
		if v.messages[i].kind != .System && v.messages[i].login == login {
			destroy_chat_message(v.messages[i])
			ordered_remove(&v.messages, i)
		}
	}
}

// Whether the message's text has one of the user's highlight phrases, as whole
// words, ignoring case.
highlighted :: proc(m: ^Chat_Message, rules: ^Chat_Rules) -> bool {
	if rules == nil || len(rules.highlights) == 0 || m.kind == .System {
		return false
	}
	text := strings.to_lower(message_plain_text(m), context.temp_allocator)
	for phrase in rules.highlights {
		if contains_words(text, phrase) {
			return true
		}
	}
	return false
}

// Whether `phrase` is in `text` with no letter or digit right before or after it.
contains_words :: proc(text, phrase: string) -> bool {
	if phrase == "" {
		return false
	}
	word_byte :: proc(c: u8) -> bool {
		return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c >= 0x80
	}
	for start := 0; start < len(text); {
		i := strings.index(text[start:], phrase)
		if i < 0 {
			return false
		}
		i += start
		end := i + len(phrase)
		if (i == 0 || !word_byte(text[i - 1]) || !word_byte(phrase[0])) && (end == len(text) || !word_byte(text[end]) || !word_byte(phrase[len(phrase) - 1])) {
			return true
		}
		start = i + 1
	}
	return false
}

// Keeps the newest CHAT_MAX_MESSAGES.
@(private = "file")
trim_messages :: proc(v: ^Chat_View) {
	if over := len(v.messages) - CHAT_MAX_MESSAGES; over > 0 {
		for m in v.messages[:over] {
			destroy_chat_message(m)
		}
		remove_range(&v.messages, 0, over)
	}
}

// Forgets every message (for a past broadcast's chat starting over).
chat_view_clear :: proc(v: ^Chat_View) {
	for m in v.messages {
		destroy_chat_message(m)
	}
	clear(&v.messages)
	clear(&v.name_hits)
	clear(&v.image_hits)
	clear(&v.message_hits)
	clear(&v.link_hits)
	clear(&v.reply_hits)
	v.scroll = 0
	v.max_scroll = 0
}

// A parsed chat filter: words the message must contain, and optionally whose it
// must be ("from:name"). Lowercase, allocated with the temp allocator.
Chat_Filter :: struct {
	words: []string,
	from:  string,
}

parse_filter :: proc(filter: string) -> (f: Chat_Filter) {
	words := make([dynamic]string, context.temp_allocator)
	rest := strings.to_lower(filter, context.temp_allocator)
	for word in strings.fields_iterator(&rest) {
		if strings.has_prefix(word, "from:") {
			f.from = strings.trim_left(word[len("from:"):], "@")
		} else {
			append(&words, word)
		}
	}
	f.words = words[:]
	return
}

// Whether the message is from `from` (by login prefix, or display name) and
// contains every word, in its text or the sender's name, ignoring case.
message_matches :: proc(m: ^Chat_Message, f: Chat_Filter) -> bool {
	name := strings.to_lower(m.name, context.temp_allocator)
	if f.from != "" {
		if m.kind == .System || (!strings.has_prefix(m.login, f.from) && !strings.has_prefix(name, f.from)) {
			return false
		}
	}
	if len(f.words) == 0 {
		return true
	}
	text := strings.to_lower(message_plain_text(m), context.temp_allocator)
	for word in f.words {
		if !strings.contains(text, word) && !strings.contains(name, word) {
			return false
		}
	}
	return true
}

@(private = "file")
apply_clear :: proc(v: ^Chat_View, m: Chat_Message) {
	for &old in v.messages {
		switch m.clear {
		case .None:
		case .Message:
			old.deleted ||= old.id == m.clear_target
		case .User:
			old.deleted ||= old.login == m.clear_target
		case .All:
			old.deleted ||= old.kind != .System
		}
	}
}

// The login of the name at (x, y), if a name is drawn there.
chat_view_name_at :: proc(v: ^Chat_View, x, y: f32) -> (login: string, found: bool) {
	for hit in v.name_hits {
		if in_rect(hit.rect, x, y) {
			return hit.login, true
		}
	}
	return "", false
}

// The message at (x, y), if one is drawn there.
chat_view_message_at :: proc(v: ^Chat_View, x, y: f32) -> (m: ^Chat_Message, found: bool) {
	for hit in v.message_hits {
		if in_rect(hit.rect, x, y) && hit.index < len(v.messages) {
			return &v.messages[hit.index], true
		}
	}
	return nil, false
}

chat_view_scroll :: proc(v: ^Chat_View, wheel_y, scale: f32) {
	v.scroll = clamp(v.scroll + wheel_y * CHAT_SCROLL_STEP * scale, 0, v.max_scroll)
}

// The address of the link at (x, y), if one is drawn there. Allocated with the
// temp allocator.
chat_view_link_at :: proc(v: ^Chat_View, x, y: f32) -> (url: string, found: bool) {
	for hit in v.link_hits {
		if in_rect(hit.rect, x, y) {
			_, url, found = chat_link(hit.link)
			return
		}
	}
	return "", false
}

// Whether (x, y) is on a reply's "Replying to" line.
chat_view_reply_at :: proc(v: ^Chat_View, x, y: f32) -> bool {
	for rect in v.reply_hits {
		if in_rect(rect, x, y) {
			return true
		}
	}
	return false
}

// Handles a click at (x, y) in pixels. Returns true if it changed the view.
chat_view_click :: proc(v: ^Chat_View, x, y: f32) -> bool {
	if v.more_bar.w > 0 && in_rect(v.more_bar, x, y) {
		v.scroll = 0
		return true
	}
	return false
}

// Draws the messages, or with a `filter` only those matching it (see
// message_matches).
draw_chat_view :: proc(a: ^Assets, v: ^Chat_View, rect: Rect, scale: f32, filter := "") {
	r := &a.renderer
	draw_rect(r, rect, CHAT_BACKGROUND)
	pad := CHAT_PADDING * scale
	gap := CHAT_MESSAGE_GAP * scale
	content_w := rect.w - 2 * pad

	clear(&v.name_hits)
	clear(&v.image_hits)
	clear(&v.message_hits)
	clear(&v.link_hits)
	clear(&v.reply_hits)
	clip_begin(r, rect)
	// Messages are laid out from the newest upwards; `bottom` is the next one's
	// bottom edge.
	bottom := rect.y + rect.h - pad + v.scroll
	total: f32
	all_measured := true
	query := parse_filter(filter)
	v.matches = 0
	for i := len(v.messages) - 1; i >= 0; i -= 1 {
		m := &v.messages[i]
		if filter != "" {
			if !message_matches(m, query) {
				continue
			}
			v.matches += 1
		}
		layout := message_layout(a, v.emotes, m, scale, content_w)
		top := bottom - layout.height
		if top < rect.y + rect.h {
			if m.mention {
				draw_rect(r, {rect.x, top - gap / 2, rect.w, layout.height + gap}, CHAT_MENTION_BACKGROUND)
			} else if m.accent != .None {
				draw_rect(r, {rect.x, top - gap / 2, rect.w, layout.height + gap}, CHAT_ACCENT_BACKGROUNDS[m.accent])
			}
			draw_message(a, v, m, layout, rect.x + pad, top)
			append(&v.message_hits, Message_Hit{{rect.x, top - gap / 2, rect.w, layout.height + gap}, i})
		}
		total += layout.height + gap
		bottom = top - gap
		if bottom < rect.y {
			// Everything older is off screen, so the full height isn't known.
			all_measured = i == 0
			break
		}
	}
	if filter != "" && v.matches == 0 {
		draw_centered(r, .Regular, CHAT_FONT_SIZE * scale, rect, "No matching messages", CHAT_SYSTEM_TEXT)
	}
	if all_measured {
		v.max_scroll = max(0, total - (rect.h - 2 * pad))
		v.scroll = min(v.scroll, v.max_scroll)
	} else {
		v.max_scroll = max(v.max_scroll, v.scroll + rect.h)
	}

	v.more_bar = {}
	if v.scroll > 0 {
		label := "More messages below"
		size := CHAT_FONT_SIZE * scale
		lw := text_width(r, .Regular, size, label)
		lh := line_height(r, .Regular, size)
		bar_h := max(CHAT_MORE_BAR_HEIGHT * scale, lh + 8 * scale)
		v.more_bar = {rect.x, rect.y + rect.h - bar_h, rect.w, bar_h}
		draw_rect(r, v.more_bar, CHAT_MORE_BAR)
		draw_text(r, .Regular, size, v.more_bar.x + (v.more_bar.w - lw) / 2, v.more_bar.y + (bar_h - lh) / 2, label, CHAT_TEXT)
	}
	clip_end(r)
}

// Draws a laid-out message with its top left at (x, y), noting in `v` where its
// name, badges, emotes and links are.
draw_message :: proc(a: ^Assets, v: ^Chat_View, m: ^Chat_Message, layout: ^Message_Layout, x, y: f32) {
	size := CHAT_FONT_SIZE * layout.scale
	alpha: u8 = CHAT_DELETED_ALPHA if m.deleted else CHAT_HISTORICAL_ALPHA if m.historical else 255
	for item in layout.items {
		rect := Rect{x + item.rect.x, y + item.rect.y, item.rect.w, item.rect.h}
		if item.is_name {
			append(&v.name_hits, Name_Hit{rect, m.login})
		}
		if item.hint != .None {
			append(&v.image_hits, Image_Hit{rect, item})
		}
		if item.link != "" {
			append(&v.link_hits, Link_Hit{rect, item.link})
		}
		if item.is_reply {
			append(&v.reply_hits, rect)
		}
		switch item.kind {
		case .Text:
			color := item.color
			color.a = u8(u32(color.a) * u32(alpha) / 255)
			draw_text(&a.renderer, item.font, size, rect.x, rect.y, item.text, color)
			if item.link != "" {
				line := max(1, layout.scale)
				draw_rect(&a.renderer, {rect.x, rect.y + rect.h - line, rect.w, line}, color)
			}
		case .Image:
			image_use(&a.jobs, item.image)
			if item.image.state != .Ready {
				continue
			}
			texture, next := image_frame(item.image, a.now_ms)
			draw_image(&a.renderer, texture, rect, {255, 255, 255, alpha})
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
	text:    string,
	image:   ^Image,
	// Part of the sender's name: clicking it opens their user card.
	is_name: bool,
	// Part of a link: clicking it opens `link` (see chat_link) in the browser.
	link:    string,
	// Part of the line saying what a reply replies to: clicking it opens the thread.
	is_reply: bool,
	// A badge (`text` is its "set/version") or emote (`text` is its name), which
	// shows a tooltip when hovered.
	hint:        Item_Hint,
	third_party: bool,
	source:      Emote_Source,
}

Item_Hint :: enum {
	None,
	Badge,
	Emote,
}

// A message laid out for one width, scale and text size. Images that finish loading can change
// sizes, so it's also redone whenever Images.version moves on.
Message_Layout :: struct {
	width:          f32,
	scale:          f32,
	text_scale:     f32,
	images_version: int,
	hide_reply:     bool,
	height:         f32,
	items:          [dynamic]Layout_Item,
}

// Lays the message out, unless its cached layout still fits.
// "Badges Name: text" for chat, "Badges Name text" in the name's colour for /me,
// grey text for system messages.
message_layout :: proc(a: ^Assets, channel: ^Emotes, m: ^Chat_Message, scale, width: f32) -> ^Message_Layout {
	return message_layout_into(a, channel, m, &m.layout, scale, width)
}

// message_layout, cached in `l` rather than the message's own layout. With
// `hide_reply`, a reply leaves out what it replies to (shown just above it).
message_layout_into :: proc(a: ^Assets, channel: ^Emotes, m: ^Chat_Message, l: ^Message_Layout, scale, width: f32, hide_reply := false) -> ^Message_Layout {
	if l.height > 0 && l.width == width && l.scale == scale && l.text_scale == a.renderer.text_scale && l.images_version == a.images.version && l.hide_reply == hide_reply {
		return l
	}
	clear(&l.items)
	l.hide_reply = hide_reply
	l.width = width
	l.scale = scale
	l.text_scale = a.renderer.text_scale
	l.images_version = a.images.version

	// Badges, emoji and emotes grow with the text.
	image_scale := scale * a.renderer.text_scale
	b := Builder {
		a     = a,
		l     = l,
		scale = image_scale,
		size  = CHAT_FONT_SIZE * scale,
		width = width,
	}
	b.text_h = line_height(&a.renderer, .Regular, b.size)
	b.line_h = b.text_h
	pixel_scale: f32 = 2 if image_scale > 1 else 1

	// Why Twitch marks it out, on a line of its own.
	if m.label != "" {
		put_text(&b, .Bold, CHAT_SYSTEM_TEXT, m.label)
		end_line(&b)
	}

	// A reply starts with what it replies to, on a line of its own, cut to fit.
	if m.reply != "" && !hide_reply {
		b.in_reply = m.thread != ""
		if text_width(&a.renderer, .Regular, b.size, m.reply) <= width {
			put_text(&b, .Regular, CHAT_SYSTEM_TEXT, m.reply)
		} else {
			ellipsis :: "…"
			room := width - text_width(&a.renderer, .Regular, b.size, ellipsis)
			put_text(&b, .Regular, CHAT_SYSTEM_TEXT, fit_prefix(&a.renderer, .Regular, b.size, m.reply, room))
			put_text(&b, .Regular, CHAT_SYSTEM_TEXT, ellipsis)
		}
		b.in_reply = false
		end_line(&b)
	}

	for key in m.badges {
		badge, found := badge_lookup(channel, &a.emotes, key)
		if !found {
			continue
		}
		image := image_get(&a.images, &a.jobs, badge.url_2x if pixel_scale > 1 && badge.url_2x != "" else badge.url_1x, pixel_scale)
		if image.state == .Failed {
			continue
		}
		put_image(&b, image, BADGE_HEIGHT, 0)
		hint_last(&b, {hint = .Badge, text = key})
		b.x += BADGE_GAP * scale
	}

	text_color := CHAT_TEXT
	switch m.kind {
	case .Chat:
		b.in_name = m.login != ""
		put_words(&b, .Bold, m.color, m.name)
		b.in_name = false
		put_text(&b, .Bold, m.color, ":")
	case .Action:
		b.in_name = m.login != ""
		put_words(&b, .Bold, m.color, m.name)
		b.in_name = false
		text_color = m.color
	case .System:
		text_color = CHAT_SYSTEM_TEXT
	}

	for f in m.fragments {
		switch f.kind {
		case .Text:
			b.links = m.kind != .System
			put_words(&b, .Regular, text_color, f.text, f.attached)
			b.links = false
		case .Emote:
			image := image_get(&a.images, &a.jobs, f.url_2x if pixel_scale > 1 && f.url_2x != "" else f.url_1x, pixel_scale)
			switch {
			case image.state == .Failed:
				put_words(&b, .Regular, text_color, f.text, f.attached)
			case f.zero_width && overlay_last(&b, image):
				// Drawn over the previous emote.
				hint_last(&b, {hint = .Emote, text = f.text, third_party = f.third_party, source = f.source})
			case f.emoji:
				if !f.attached {
					space(&b, .Regular)
				}
				put_image(&b, image, EMOJI_HEIGHT, 0)
			case:
				space(&b, .Regular)
				put_image(&b, image, EMOTE_HEIGHT, EMOTE_OVERHANG)
				hint_last(&b, {hint = .Emote, text = f.text, third_party = f.third_party, source = f.source})
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
	// For images: the display scale times the text size.
	scale:      f32,
	size:       f32,
	width:      f32,
	text_h:     f32,
	// The pen, and the current line's top, height and first item.
	x:          f32,
	line_y:     f32,
	line_h:     f32,
	line_start: int,
	// Words put now are the sender's name, a reply's line, or may be links.
	in_name:    bool,
	in_reply:   bool,
	links:      bool,
	// The link the word being put is part of.
	link:       string,
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
// allows (square until it has first loaded; an evicted image keeps its size).
@(private = "file")
image_size :: proc(b: ^Builder, image: ^Image, height: f32) -> [2]f32 {
	aspect: f32 = 1
	if image.size.y > 0 {
		aspect = image.size.x / image.size.y
	}
	return {height * aspect, height} * b.scale
}

@(private = "file")
put_image :: proc(b: ^Builder, image: ^Image, height, overhang: f32) {
	size := image_size(b, image, height)
	place(b, {kind = .Image, image = image}, size.x, size.y, overhang * b.scale)
}

// Gives the item just put what its tooltip shows.
@(private = "file")
hint_last :: proc(b: ^Builder, hint: Layout_Item) {
	last := &b.l.items[len(b.l.items) - 1]
	last.hint, last.text = hint.hint, hint.text
	last.third_party, last.source = hint.third_party, hint.source
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

// Puts space-separated words, wrapping between words. With `attached`, the first
// word joins what's before it unless the text starts with whitespace.
@(private = "file")
put_words :: proc(b: ^Builder, font: Font, color: Color, text: string, attached := false) {
	glued := attached && len(text) > 0 && text[0] != ' '
	rest := text
	for word in strings.fields_iterator(&rest) {
		if !glued {
			space(b, font)
		}
		glued = false
		if link, _, is_link := chat_link(word); b.links && is_link {
			b.link = link
			put_word(b, font, CHAT_LINK, word)
			b.link = ""
		} else {
			put_word(b, font, color, word)
		}
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
	place(b, {kind = .Text, font = font, color = color, text = text, is_name = b.in_name, link = b.link, is_reply = b.in_reply}, w, b.text_h)
}

CHAT_TOOLTIP_BACKGROUND :: Color{0x0e, 0x0e, 0x10, 245}
// How tall a hovered emote or badge shows in its tooltip, in logical pixels.
TOOLTIP_EMOTE_HEIGHT :: 64
TOOLTIP_BADGE_HEIGHT :: 36

// The tooltip for the badge or emote under (x, y), if any: it bigger, with its
// name and where it's from, above it (or below, without room), kept inside
// `bounds`.
draw_chat_tooltip :: proc(a: ^Assets, v: ^Chat_View, view_rect, bounds: Rect, x, y, scale: f32) {
	if !in_rect(view_rect, x, y) {
		return
	}
	hit: Image_Hit
	found := false
	// The last match is on top: a zero-width emote over the one it covers.
	for h in v.image_hits {
		if in_rect(h.rect, x, y) {
			hit, found = h, true
		}
	}
	if !found {
		return
	}
	item := hit.item
	title, detail: string
	height: f32
	switch item.hint {
	case .None:
		return
	case .Badge:
		badge, known := badge_lookup(v.emotes, &a.emotes, item.text)
		title = badge.title if known && badge.title != "" else item.text
		height = TOOLTIP_BADGE_HEIGHT
	case .Emote:
		title, detail = item.text, emote_source_label(item.third_party, item.source)
		height = TOOLTIP_EMOTE_HEIGHT
	}

	r := &a.renderer
	pad := 8 * scale
	size := CHAT_FONT_SIZE * scale
	lh := line_height(r, .Regular, size)
	image_h := height * scale * r.text_scale
	image_w := image_h * item.rect.w / max(item.rect.h, 1)
	text_w := max(text_width(r, .Bold, size, title), text_width(r, .Regular, size, detail))
	box_w := min(max(image_w, text_w) + 2 * pad, bounds.w)
	lines: f32 = 2 if detail != "" else 1
	box_h := pad + image_h + pad / 2 + lines * lh + pad
	box := Rect{hit.rect.x + (hit.rect.w - box_w) / 2, hit.rect.y - box_h - 4 * scale, box_w, box_h}
	if box.y < bounds.y {
		box.y = hit.rect.y + hit.rect.h + 4 * scale
	}
	box.x = clamp(box.x, bounds.x, bounds.x + bounds.w - box.w)
	box.y = clamp(box.y, bounds.y, bounds.y + bounds.h - box.h)

	draw_rect(r, box, CHAT_TOOLTIP_BACKGROUND)
	if item.image != nil && item.image.state == .Ready {
		texture, next := image_frame(item.image, a.now_ms)
		draw_image(r, texture, {box.x + (box.w - image_w) / 2, box.y + pad, image_w, image_h})
		if next >= 0 && (a.next_frame_ms < 0 || next < a.next_frame_ms) {
			a.next_frame_ms = next
		}
	}
	ty := box.y + pad + image_h + pad / 2
	inner := box.w - 2 * pad
	title = fit_text(r, .Bold, size, title, inner)
	draw_text(r, .Bold, size, box.x + (box.w - text_width(r, .Bold, size, title)) / 2, ty, title, CHAT_TEXT)
	if detail != "" {
		draw_text(r, .Regular, size, box.x + (box.w - text_width(r, .Regular, size, detail)) / 2, ty + lh, detail, CHAT_SYSTEM_TEXT)
	}
}
