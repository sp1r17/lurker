package app

import "core:slice"
import "core:strings"

// The button beside the chat box opens every emote the user can send here, to
// click one into the box.

// How many emote rows the panel shows at once.
EMOTE_PANEL_ROWS :: 7

Panel_Item :: struct {
	// Point into the emotes they're from, valid until those change.
	name:  string,
	emote: Emote,
}

Panel_Section :: struct {
	label: string,
	items: [dynamic]Panel_Item,
}

// Where a cell was drawn, from the last draw: as an index into the sections'
// items taken in order.
Emote_Cell :: struct {
	rect:  Rect,
	index: int,
}

// The emotes to list, in sections: the user's Twitch emotes by where they're from
// (this channel's first), then the channel's and global third-party ones. Where sets
// share a name, the first is kept. Allocated with the temp allocator.
emote_panel_sections :: proc(user: ^User_Emotes, channel_login: string, channel, global: ^Emotes) -> []Panel_Section {
	sections := make([dynamic]Panel_Section, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	section_for :: proc(sections: ^[dynamic]Panel_Section, label: string) -> ^Panel_Section {
		for &s in sections {
			if s.label == label {
				return &s
			}
		}
		append(sections, Panel_Section{label = label, items = make([dynamic]Panel_Item, context.temp_allocator)})
		return &sections[len(sections) - 1]
	}
	if user != nil {
		for name, e in user {
			if user_emote_usable(e, channel_login) {
				seen[name] = true
				append(&section_for(&sections, e.label).items, Panel_Item{name, e.emote})
			}
		}
		// This channel's own first, then Twitch's, then the rest by name.
		rank :: proc(label, channel: string) -> int {
			switch {
			case label == channel || strings.has_prefix(label, channel) && strings.has_suffix(label, " follower"):
				return 0
			case label == "Twitch":
				return 1
			}
			return 2
		}
		slice.sort_by(sections[:], proc(a, b: Panel_Section) -> bool {
			return a.label < b.label
		})
		// Stable by rank, keeping the name order above.
		ranked := make([dynamic]Panel_Section, context.temp_allocator)
		for want in 0 ..< 3 {
			for s in sections {
				if rank(s.label, channel_login) == want {
					append(&ranked, s)
				}
			}
		}
		sections = ranked
	}
	for e in ([]^Emotes{channel, global}) {
		if e == nil {
			continue
		}
		for &set, source in e.sets {
			section: ^Panel_Section
			for name, emote in set {
				if name in seen {
					continue
				}
				seen[name] = true
				if section == nil {
					section = section_for(&sections, PICKER_SOURCE_LABELS[source])
				}
				append(&section.items, Panel_Item{name, emote})
			}
		}
	}
	for &s in sections {
		slice.sort_by(s.items[:], proc(a, b: Panel_Item) -> bool {
			return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
		})
	}
	return sections[:]
}

// Whether the pane has the button: there's a chat to send to.
pane_has_emote_button :: proc(app: ^App, p: ^Chat_Pane) -> bool {
	return p.channel != "" && app.signed_in && !pane_replaying(app, p)
}

// A click on the button or the panel. Returns true if it was one.
emote_panel_click :: proc(app: ^App, p: ^Chat_Pane, x, y: f32) -> bool {
	if p.emote_button.w > 0 && in_rect(p.emote_button, x, y) {
		p.emote_panel = !p.emote_panel
		p.emote_scroll = 0
		return true
	}
	if !p.emote_panel || !in_rect(p.emote_rect, x, y) {
		return false
	}
	for cell in p.emote_cells {
		if !in_rect(cell.rect, x, y) {
			continue
		}
		index := cell.index
		for s in emote_panel_sections(&app.assets.user_emotes, p.channel, &p.emotes, &app.assets.emotes) {
			if index < len(s.items) {
				emote_panel_insert(app, p, s.items[index].name)
				break
			}
			index -= len(s.items)
		}
		break
	}
	return true
}

// Puts `name` and a space at the cursor, with one before if the text ends in a word.
@(private = "file")
emote_panel_insert :: proc(app: ^App, p: ^Chat_Pane, name: string) {
	box_focus(app, p, .Chat)
	ti := &p.boxes[.Chat]
	before := input_text(ti)[:ti.cursor]
	if before != "" && !strings.has_suffix(before, " ") {
		input_insert(ti, " ")
	}
	input_insert(ti, strings.concatenate({name, " "}, context.temp_allocator))
}

// Scrolls the panel, if (x, y) is over it.
emote_panel_scroll :: proc(app: ^App, p: ^Chat_Pane, x, y, wheel_y: f32) -> bool {
	if !p.emote_panel || !in_rect(p.emote_rect, x, y) {
		return false
	}
	p.emote_scroll = clamp(p.emote_scroll - wheel_y * CHAT_SCROLL_STEP * app.scale, 0, p.emote_max_scroll)
	return true
}

// The button, and when it's open the panel above the chat box.
draw_emote_panel :: proc(app: ^App, p: ^Chat_Pane) {
	clear(&p.emote_cells)
	if p.emote_button.w == 0 {
		p.emote_panel = false
		p.emote_rect = {}
		return
	}
	a := &app.assets
	r := &a.renderer
	scale := app.scale
	size := CHAT_FONT_SIZE * scale
	small := BROWSE_CARD_TEXT_SIZE * scale
	pad := CHAT_PADDING * scale

	hovered := in_rect(p.emote_button, app.mouse.x, app.mouse.y)
	draw_rect(r, p.emote_button, BROWSE_ACCENT if p.emote_panel else (BROWSE_CARD_HOVER if hovered else INPUT_BACKGROUND))
	draw_centered(r, .Bold, size, p.emote_button, ":)", CHAT_TEXT)
	if !p.emote_panel {
		p.emote_rect = {}
		return
	}

	cell := EMOTE_HEIGHT * scale * r.text_scale + pad
	lh_small := line_height(r, .Regular, small)
	box := p.reply_rect if p.reply_rect.w > 0 else p.input_rect
	panel_w := p.emote_button.x + p.emote_button.w - box.x
	cols := max(1, int((panel_w - pad) / cell))
	list_h := min(EMOTE_PANEL_ROWS * cell, p.messages_rect.h - lh_small - 3 * pad)
	list_h = max(list_h, cell)
	foot_h := lh_small + pad
	panel_h := list_h + foot_h
	panel := Rect{box.x, box.y - 4 * scale - panel_h, panel_w, panel_h}
	p.emote_rect = panel
	draw_rect(r, panel, PICKER_BACKGROUND)

	sections := emote_panel_sections(&a.user_emotes, p.channel, &p.emotes, &a.emotes)
	list := Rect{panel.x, panel.y, panel.w, list_h}
	total: f32
	for s in sections {
		if len(s.items) > 0 {
			total += lh_small + pad / 2 + f32((len(s.items) + cols - 1) / cols) * cell
		}
	}
	p.emote_max_scroll = max(0, total - list_h)
	p.emote_scroll = clamp(p.emote_scroll, 0, p.emote_max_scroll)
	if total == 0 {
		draw_text(r, .Regular, small, panel.x + pad, panel.y + pad / 2, "No emotes yet.", CHAT_SYSTEM_TEXT)
	}

	pixel_scale: f32 = 2 if scale * r.text_scale > 1 else 1
	emote_h := cell - pad
	hover_name, hover_label: string
	clip_begin(r, list)
	y := list.y - p.emote_scroll
	index := 0
	for s in sections {
		if len(s.items) == 0 {
			continue
		}
		if y + lh_small >= list.y && y <= list.y + list_h {
			draw_text(r, .Bold, small, panel.x + pad, y, s.label, BROWSE_DIM_TEXT)
		}
		y += lh_small + pad / 2
		for item, i in s.items {
			row, col := i / cols, i % cols
			rect := Rect{panel.x + pad / 2 + f32(col) * cell, y + f32(row) * cell, cell, cell}
			if rect.y + cell < list.y || rect.y > list.y + list_h {
				continue
			}
			append(&p.emote_cells, Emote_Cell{rect, index + i})
			if in_rect(rect, app.mouse.x, app.mouse.y) && in_rect(list, app.mouse.x, app.mouse.y) {
				draw_rect(r, rect, MENU_HOVER)
				hover_name, hover_label = item.name, s.label
			}
			url := item.emote.url_2x if pixel_scale > 1 && item.emote.url_2x != "" else item.emote.url_1x
			image := image_get(&a.images, &a.jobs, url, pixel_scale)
			if image.state == .Ready && image.size.y > 0 {
				// As tall as the row, unless that makes it wider than its cell.
				w := emote_h * image.size.x / image.size.y
				h := emote_h
				if w > cell {
					w, h = cell, cell * image.size.y / image.size.x
				}
				texture, next := image_frame(image, a.now_ms)
				draw_image(r, texture, {rect.x + (cell - w) / 2, rect.y + (cell - h) / 2, w, h})
				if next >= 0 && (a.next_frame_ms < 0 || next < a.next_frame_ms) {
					a.next_frame_ms = next
				}
			}
		}
		y += f32((len(s.items) + cols - 1) / cols) * cell
		index += len(s.items)
	}
	clip_end(r)

	if hover_name != "" {
		text := strings.concatenate({hover_name, "  ·  ", hover_label}, context.temp_allocator)
		draw_text(r, .Regular, small, panel.x + pad, panel.y + list_h + pad / 2, fit_text(r, .Regular, small, text, panel.w - 2 * pad), CHAT_TEXT)
	}
}
