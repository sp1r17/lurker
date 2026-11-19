package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

// What the user watched, newest first: live streams, videos and clips, shown on
// the History tab and saved in history.json beside the layout.

HISTORY_MAX :: 200
// The format history.json is saved in (see saved.odin).
HISTORY_VERSION :: 1

History_Kind :: enum {
	Live,
	Video,
	Clip,
}

// Strings owned.
History_Entry :: struct {
	kind:         History_Kind,
	// The channel's login for a live stream, the video's ID, or the clip's slug.
	id:           string,
	login:        string,
	channel_name: string,
	title:        string,
	game:         string,
	// When it was last watched, in Unix seconds.
	at:           i64,
}

History :: struct {
	entries: [dynamic]History_Entry,
}

@(private = "file")
destroy_history_entry :: proc(e: History_Entry) {
	delete(e.id)
	delete(e.login)
	delete(e.channel_name)
	delete(e.title)
	delete(e.game)
}

history_destroy :: proc(h: ^History) {
	for e in h.entries {
		destroy_history_entry(e)
	}
	delete(h.entries)
}

// Puts `e` (borrowed strings) first, in place of an earlier entry for the same
// thing, and saves.
history_add :: proc(h: ^History, e: History_Entry) {
	if e.id == "" {
		return
	}
	for old, i in h.entries {
		if old.kind == e.kind && old.id == e.id {
			destroy_history_entry(old)
			ordered_remove(&h.entries, i)
			break
		}
	}
	inject_at(
		&h.entries,
		0,
		History_Entry {
			kind = e.kind,
			id = strings.clone(e.id),
			login = strings.clone(e.login),
			channel_name = strings.clone(e.channel_name),
			title = strings.clone(e.title),
			game = strings.clone(e.game),
			at = e.at if e.at != 0 else time.to_unix_seconds(time.now()),
		},
	)
	for len(h.entries) > HISTORY_MAX {
		destroy_history_entry(pop(&h.entries))
	}
	history_save(h)
}

// Fills in the live stream `login`'s title and category once they're known,
// keeping its place.
history_update_live :: proc(h: ^History, login, name, title, game: string) {
	for &e in h.entries {
		if e.kind != .Live || e.id != login {
			continue
		}
		if e.title == title && e.game == game && (name == "" || e.channel_name == name) {
			return
		}
		delete(e.title)
		delete(e.game)
		e.title = strings.clone(title)
		e.game = strings.clone(game)
		if name != "" {
			delete(e.channel_name)
			e.channel_name = strings.clone(name)
		}
		history_save(h)
		return
	}
}

history_remove :: proc(h: ^History, i: int) {
	if i < 0 || i >= len(h.entries) {
		return
	}
	destroy_history_entry(h.entries[i])
	ordered_remove(&h.entries, i)
	history_save(h)
}

history_clear :: proc(h: ^History) {
	for e in h.entries {
		destroy_history_entry(e)
	}
	clear(&h.entries)
	history_save(h)
}

@(private = "file")
History_File :: struct {
	version: int,
	entries: []History_Entry,
}

history_load :: proc() -> (h: History) {
	path, ok := state_path("history.json")
	if !ok {
		return
	}
	data, _, read := saved_read(path, HISTORY_VERSION)
	if read == .Read && !parse_watch_history(data, &h) {
		saved_unreadable(path)
	}
	return
}

parse_watch_history :: proc(data: []byte, h: ^History) -> bool {
	saved: History_File
	if json.unmarshal(data, &saved, allocator = context.temp_allocator) != nil {
		return false
	}
	for e in saved.entries {
		if e.id == "" || int(e.kind) < 0 || int(e.kind) >= len(History_Kind) || len(h.entries) >= HISTORY_MAX {
			continue
		}
		append(
			&h.entries,
			History_Entry {
				kind = e.kind,
				id = strings.clone(e.id),
				login = strings.clone(e.login),
				channel_name = strings.clone(e.channel_name),
				title = strings.clone(e.title),
				game = strings.clone(e.game),
				at = e.at,
			},
		)
	}
	return true
}

history_save :: proc(h: ^History) {
	path, ok := state_path("history.json")
	if !ok {
		return
	}
	data, err := json.marshal(History_File{HISTORY_VERSION, h.entries[:]}, {pretty = true, use_enum_names = true}, context.temp_allocator)
	if err != nil {
		return
	}
	save_file(path, data)
}

// "3 hours ago": how long before `now` (Unix seconds) `at` was. Allocated with
// the temp allocator.
format_ago :: proc(at, now: i64) -> string {
	minutes := max(0, int((now - at) / 60))
	unit, n := "minute", minutes
	switch {
	case minutes < 1:
		return "Just now"
	case minutes >= 60 * 24 * 365:
		unit, n = "year", minutes / (60 * 24 * 365)
	case minutes >= 60 * 24 * 30:
		unit, n = "month", minutes / (60 * 24 * 30)
	case minutes >= 60 * 24:
		unit, n = "day", minutes / (60 * 24)
	case minutes >= 60:
		unit, n = "hour", minutes / 60
	}
	return fmt.tprintf("%d %s%s ago", n, unit, "" if n == 1 else "s")
}

@(rodata)
HISTORY_KIND_LABELS := [History_Kind]string {
	.Live  = "LIVE",
	.Video = "VIDEO",
	.Clip  = "CLIP",
}

// The History tab: what was watched, newest first, a row each with a button to
// take it out, and one to clear it all.
draw_history :: proc(app: ^App, content: Rect) {
	a := &app.assets
	r := &a.renderer
	b := &app.browse
	h := &app.history
	scale := app.scale
	pad := BROWSE_PADDING * scale
	gap := 6 * scale
	name_size := BROWSE_CARD_TITLE_SIZE * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	lh_name := line_height(r, .Bold, name_size)
	lh_text := line_height(r, .Regular, text_size)
	row_h := lh_name + lh_text + 2 * 10 * scale
	width := min(content.w - 2 * pad, BROWSE_RESULTS_WIDTH * scale * r.text_scale)
	resize(&b.history_remove, len(h.entries))
	b.history_clear = {}

	if len(h.entries) == 0 {
		draw_text(r, .Regular, text_size, content.x + pad, content.y + pad, "Streams, videos and clips you watch show up here.", BROWSE_DIM_TEXT)
		return
	}
	button :: proc(app: ^App, right, mid_y: f32, label: string) -> Rect {
		r := &app.assets.renderer
		size := BROWSE_CARD_TEXT_SIZE * app.scale
		bw := text_width(r, .Bold, size, label) + 24 * app.scale
		bh := line_height(r, .Bold, size) + 12 * app.scale
		rect := Rect{right - bw, mid_y - bh / 2, bw, bh}
		hovered := in_rect(rect, app.mouse.x, app.mouse.y)
		draw_rect(r, rect, SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON)
		draw_centered(r, .Bold, size, rect, label, BROWSE_TEXT)
		return rect
	}

	heading_h := lh_name + pad
	total_h := pad + heading_h + f32(len(h.entries)) * (row_h + gap) + pad
	scroll := &b.scroll[.History]
	b.max_scroll[.History] = max(0, total_h - content.h)
	scroll^ = clamp(scroll^, 0, b.max_scroll[.History])

	clip_begin(r, content)
	x := content.x + pad
	y := content.y + pad - scroll^
	draw_text(r, .Bold, BROWSE_TAB_SIZE * scale, x, y + (heading_h - lh_name) / 2 - pad / 2, fmt.tprintf("Watched (%d)", len(h.entries)), BROWSE_DIM_TEXT)
	b.history_clear = button(app, x + width, y + heading_h / 2 - pad / 2, "Clear history")
	y += heading_h
	now := time.to_unix_seconds(time.now())
	for e, i in h.entries {
		row := Rect{x, y, width, row_h}
		y += row_h + gap
		append(&b.cards, row)
		b.history_remove[i] = {}
		if row.y > content.y + content.h || row.y + row.h < content.y {
			continue
		}
		draw_rect(r, row, BROWSE_CARD_HOVER if i == b.hovered else BROWSE_PLACEHOLDER)
		remove := button(app, row.x + row.w - 10 * scale, row.y + row.h / 2, "Remove")
		b.history_remove[i] = remove

		// The kind, as a badge, then the channel and what it was.
		tx := row.x + 12 * scale
		ty := row.y + 10 * scale
		label := HISTORY_KIND_LABELS[e.kind]
		tag := Rect{tx, ty + (lh_name - lh_text - 4 * scale) / 2, text_width(r, .Bold, text_size, label) + 12 * scale, lh_text + 4 * scale}
		draw_rect(r, tag, LIVE_RED if e.kind == .Live else VIEWERS_BACKGROUND)
		draw_centered(r, .Bold, text_size, tag, label, BROWSE_TEXT)
		nx := tag.x + tag.w + 10 * scale
		tw := remove.x - 12 * scale - nx
		name := e.channel_name if e.channel_name != "" else e.login
		draw_text(r, .Bold, name_size, nx, ty, fit_text(r, .Bold, name_size, name, tw), BROWSE_TEXT)
		detail := format_ago(e.at, now)
		if e.title != "" {
			detail = fmt.tprintf("%s · %s", detail, e.title)
		}
		if e.game != "" {
			detail = fmt.tprintf("%s · %s", detail, e.game)
		}
		draw_text(r, .Regular, text_size, tx, ty + lh_name, fit_text(r, .Regular, text_size, detail, remove.x - 12 * scale - tx), BROWSE_DIM_TEXT)
	}
	clip_end(r)
}

// A click on the History tab: a row's Remove button, Clear history, or a row,
// which watches it again (a live stream's channel; a video or clip looked up
// afresh, as from a link). Returns true if it hit one.
history_click :: proc(app: ^App, x, y: f32, card: int) -> bool {
	b := &app.browse
	h := &app.history
	if b.history_clear.w > 0 && in_rect(b.history_clear, x, y) {
		history_clear(h)
		b.hovered = -1
		return true
	}
	for rect, i in b.history_remove {
		if rect.w > 0 && in_rect(rect, x, y) {
			history_remove(h, i)
			b.hovered = -1
			return true
		}
	}
	if card < 0 || card >= len(h.entries) {
		return false
	}
	e := h.entries[card]
	switch e.kind {
	case .Live:
		watch_start(app, strings.clone(e.id, context.temp_allocator))
	case .Video:
		open_link(app, {kind = .Video, id = e.id})
	case .Clip:
		open_link(app, {kind = .Clip, id = e.id})
	}
	return true
}
