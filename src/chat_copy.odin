package app

import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// Behind selected chat text.
CHAT_SELECTION :: Color{0x46, 0x6e, 0xd8, 150}

// A place in a chat view's text: byte `offset` of item `item` of message
// `message` (an index into Chat_View.messages). For an image, 1 is after it.
// Words keep their items however the message is laid out, so a selection stays
// on them as messages arrive, images load or the chat is resized.
Chat_Point :: struct {
	message, item, offset: int,
}

// Text selected by dragging over a chat, for Ctrl+C.
Chat_Selection :: struct {
	// The left button went down on the messages at `from`; past DRAG_THRESHOLD,
	// moving it selects.
	pressed:  bool,
	dragging: bool,
	from:     [2]f32,
	anchor:   Chat_Point,
	focus:    Chat_Point,
	// Something is selected.
	shown:    bool,
}

@(private = "file")
point_before :: proc(a, b: Chat_Point) -> bool {
	if a.message != b.message {
		return a.message < b.message
	}
	if a.item != b.item {
		return a.item < b.item
	}
	return a.offset < b.offset
}

@(private = "file")
selection_range :: proc(s: Chat_Selection) -> (start, end: Chat_Point) {
	if point_before(s.focus, s.anchor) {
		return s.focus, s.anchor
	}
	return s.anchor, s.focus
}

// Moves the selection with its messages when `by` are added before them
// (negative when removed), dropping it if that removed them.
chat_selection_shift :: proc(v: ^Chat_View, by: int) {
	s := &v.selection
	s.anchor.message += by
	s.focus.message += by
	if s.anchor.message < 0 || s.focus.message < 0 {
		s^ = {}
	}
}

// The part of item `item` of message `message` that's selected, as bytes
// [from, to) of its `length` (1 for an image).
selected_part :: proc(v: ^Chat_View, message, item, length: int) -> (from, to: int, ok: bool) {
	if !v.selection.shown {
		return
	}
	start, end := selection_range(v.selection)
	if message < start.message || message > end.message {
		return
	}
	from, to = 0, length
	if message == start.message {
		if item < start.item {
			return
		}
		if item == start.item {
			from = min(start.offset, length)
		}
	}
	if message == end.message {
		if item > end.item {
			return
		}
		if item == end.item {
			to = min(end.offset, length)
		}
	}
	return from, to, from < to
}

@(private = "file")
item_length :: proc(item: Layout_Item) -> int {
	return len(item.text) if item.kind == .Text else 1
}

// The place in the text nearest (x, y), in the messages drawn last.
chat_view_point_at :: proc(a: ^Assets, v: ^Chat_View, x, y: f32) -> (point: Chat_Point, ok: bool) {
	// The message under y, or the nearest one drawn.
	best := -1
	best_d := max(f32)
	for hit, i in v.message_hits {
		d: f32 = 0
		if y < hit.rect.y {
			d = hit.rect.y - y
		} else if y > hit.rect.y + hit.rect.h {
			d = y - (hit.rect.y + hit.rect.h)
		}
		if d < best_d {
			best, best_d = i, d
		}
	}
	if best < 0 || v.message_hits[best].index >= len(v.messages) {
		return {}, false
	}
	hit := v.message_hits[best]
	l := &v.messages[hit.index].layout
	if len(l.items) == 0 {
		return {hit.index, 0, 0}, true
	}
	lx, ly := x - hit.origin.x, y - hit.origin.y
	// The nearest item: on the nearest line, then the nearest along it.
	pick := 0
	pick_dy, pick_dx := max(f32), max(f32)
	for item, i in l.items {
		r := item.rect
		dy := r.y - ly if ly < r.y else ly - (r.y + r.h) if ly > r.y + r.h else 0
		dx := r.x - lx if lx < r.x else lx - (r.x + r.w) if lx > r.x + r.w else 0
		if dy < pick_dy || dy == pick_dy && dx < pick_dx {
			pick, pick_dy, pick_dx = i, dy, dx
		}
	}
	item := l.items[pick]
	if item.kind == .Image {
		return {hit.index, pick, 0 if lx < item.rect.x + item.rect.w / 2 else 1}, true
	}
	// The character boundary nearest lx.
	size := CHAT_FONT_SIZE * l.scale
	offset := 0
	left: f32 = 0
	for i := 0; i < len(item.text); {
		_, n := utf8.decode_rune_in_string(item.text[i:])
		right := text_width(&a.renderer, item.font, size, item.text[:i + n])
		if item.rect.x + right > lx {
			offset = i if lx - (item.rect.x + left) < item.rect.x + right - lx else i + n
			break
		}
		left = right
		i += n
		offset = i
	}
	return {hit.index, pick, offset}, true
}

// A left press on the messages at (x, y): what was selected goes, and dragging
// from here selects.
chat_select_press :: proc(a: ^Assets, v: ^Chat_View, x, y: f32) {
	v.selection = {}
	if point, ok := chat_view_point_at(a, v, x, y); ok {
		v.selection = {pressed = true, from = {x, y}, anchor = point, focus = point}
	}
}

// The mouse moved with the left button held. Past the top or bottom of `rect`
// (the messages), the chat scrolls to select further. Returns whether the
// selection changed.
chat_select_motion :: proc(a: ^Assets, v: ^Chat_View, rect: Rect, x, y, scale: f32) -> bool {
	s := &v.selection
	if !s.pressed {
		return false
	}
	if !s.dragging {
		d := [2]f32{x, y} - s.from
		threshold := DRAG_THRESHOLD * scale
		if d.x * d.x + d.y * d.y < threshold * threshold {
			return false
		}
		s.dragging = true
	}
	if y < rect.y {
		chat_view_scroll(v, 1, scale)
	} else if y > rect.y + rect.h {
		chat_view_scroll(v, -1, scale)
	}
	if point, ok := chat_view_point_at(a, v, clamp(x, rect.x, rect.x + rect.w), clamp(y, rect.y, rect.y + rect.h)); ok {
		s.focus = point
	}
	s.shown = s.focus != s.anchor
	return true
}

// The left button came up: a selection made is kept, and on Linux becomes the
// primary selection, for pasting with the middle button.
chat_select_release :: proc(v: ^Chat_View) {
	s := &v.selection
	if !s.pressed {
		return
	}
	s.pressed, s.dragging = false, false
	// An `if`, not `when`: elsewhere sdl would be imported unused, which -vet refuses.
	if ODIN_OS == .Linux && s.shown {
		_ = sdl.SetPrimarySelectionText(strings.clone_to_cstring(chat_selection_text(v), context.temp_allocator))
	}
}

// The selected text as it reads: emotes by name, without badges, a message per
// line. Allocated with the temp allocator.
chat_selection_text :: proc(v: ^Chat_View) -> string {
	if !v.selection.shown {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	start, end := selection_range(v.selection)
	for mi in start.message ..= min(end.message, len(v.messages) - 1) {
		items := v.messages[mi].layout.items[:]
		prev: Layout_Item
		wrote := false
		for item, j in items {
			from, to, ok := selected_part(v, mi, j, item_length(item))
			if !ok || item.kind == .Image && (item.hint == .Badge || item.hint == .Room || item.text == "") {
				continue
			}
			text := item.text[from:to] if item.kind == .Text else item.text
			switch {
			case !wrote && strings.builder_len(b) > 0:
				strings.write_byte(&b, '\n')
			case wrote:
				// A space where the layout left one, or where the line wrapped (or
				// a zero-width emote went over the one before).
				gap := item.rect.x - (prev.rect.x + prev.rect.w)
				if gap > 0.5 || item.rect.x < prev.rect.x + prev.rect.w - 0.5 {
					strings.write_byte(&b, ' ')
				}
			}
			strings.write_string(&b, text)
			prev, wrote = item, true
		}
	}
	return strings.to_string(b)
}

// Draws the highlight behind item `j` of message `index`, laid out in `l` and
// drawn at `rect`, as far as it's selected: through the space to the next item
// when that's selected too, on the same line.
draw_selection :: proc(a: ^Assets, v: ^Chat_View, l: ^Message_Layout, index, j: int, rect: Rect) {
	item := l.items[j]
	from, to, ok := selected_part(v, index, j, item_length(item))
	if !ok {
		return
	}
	x0, x1 := rect.x, rect.x + rect.w
	if item.kind == .Text {
		size := CHAT_FONT_SIZE * l.scale
		if from > 0 {
			x0 = rect.x + text_width(&a.renderer, item.font, size, item.text[:from])
		}
		if to < len(item.text) {
			x1 = rect.x + text_width(&a.renderer, item.font, size, item.text[:to])
		}
	}
	if to == item_length(item) && j + 1 < len(l.items) {
		next := l.items[j + 1]
		next_from, _, next_ok := selected_part(v, index, j + 1, item_length(next))
		if next_ok && next_from == 0 && next.rect.y == item.rect.y && next.rect.x > item.rect.x + item.rect.w {
			x1 = rect.x + (next.rect.x - item.rect.x)
		}
	}
	draw_rect(&a.renderer, {x0, rect.y, x1 - x0, rect.h}, CHAT_SELECTION)
}

Message_Action :: enum {
	Reply,
	Copy_Message,
}

// The right-click menu for a chat message: replying to it and copying it.
Message_Menu :: struct {
	open:       bool,
	at:         [2]f32,
	// The pane it's in (Chat_Pane.id), and the message by Twitch's ID, for
	// replying: the message itself can move as others arrive. Owned.
	pane:       int,
	message_id: string,
	// What Copy message copies. Owned.
	text:       string,
	// Set while drawing.
	rects:      [len(Message_Action)]Rect,
	actions:    [len(Message_Action)]Message_Action,
	count:      int,
}

message_menu_close :: proc(m: ^Message_Menu) {
	delete(m.message_id)
	delete(m.text)
	m^ = {}
}

// Opens the menu at (x, y) for message `m` of pane `p`.
message_menu_open :: proc(app: ^App, p: ^Chat_Pane, m: ^Chat_Message, x, y: f32) {
	menu := &app.watch.message_menu
	message_menu_close(menu)
	menu^ = {
		open       = true,
		at         = {x, y},
		pane       = p.id,
		message_id = strings.clone(m.id) if can_reply(app, p, m) else "",
		text       = strings.clone(message_plain_text(m)),
	}
}

// A click while the menu is open: does what was clicked, and closes it. Returns
// false if it wasn't open.
message_menu_click :: proc(app: ^App, x, y: f32) -> bool {
	menu := &app.watch.message_menu
	if !menu.open {
		return false
	}
	for rect, i in menu.rects[:menu.count] {
		if !in_rect(rect, x, y) {
			continue
		}
		switch menu.actions[i] {
		case .Reply:
			p := find_pane(app, menu.pane)
			if p == nil {
				break
			}
			for &m in p.view.messages {
				if m.id == menu.message_id {
					pane_reply_start(app, p, &m)
					break
				}
			}
		case .Copy_Message:
			copy_text(menu.text)
		}
		break
	}
	message_menu_close(menu)
	return true
}

// The menu at the mouse, kept inside `screen`.
draw_message_menu :: proc(app: ^App, screen: Rect) {
	menu := &app.watch.message_menu
	menu.count = 0
	if !menu.open {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	item_h := MENU_ITEM_HEIGHT * scale * r.text_scale
	labels := [Message_Action]string {
		.Reply        = "Reply",
		.Copy_Message = "Copy message",
	}
	if menu.message_id != "" {
		menu.actions[menu.count] = .Reply
		menu.count += 1
	}
	menu.actions[menu.count] = .Copy_Message
	menu.count += 1

	menu_w := MENU_WIDTH * scale
	for action in menu.actions[:menu.count] {
		menu_w = max(menu_w, text_width(r, .Bold, size, labels[action]) + 50 * scale)
	}
	menu_h := item_h * f32(menu.count)
	box := Rect{min(menu.at.x, screen.x + screen.w - menu_w), min(menu.at.y, screen.y + screen.h - menu_h), menu_w, menu_h}
	hidden := menu_hover_begin(app, box)
	defer menu_hover_end(app, hidden)
	draw_rect(r, {box.x - scale, box.y - scale, box.w + 2 * scale, box.h + 2 * scale}, USER_CARD_BORDER)
	draw_rect(r, box, USER_CARD_BACKGROUND)
	for action, i in menu.actions[:menu.count] {
		rect := Rect{box.x, box.y + item_h * f32(i), box.w, item_h}
		menu.rects[i] = rect
		draw_menu_item(app, rect, labels[action], false)
	}
}
