package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Block_Kind :: enum {
	Channel,
	Category,
}

// Channels and categories the user never wants to see: they're left out of the
// stream lists, the categories, search results, the offline follows and live
// notifications. Saved in blocked.json beside the layout.
Blocked :: struct {
	// Owned. Channels by login; categories by name, as Twitch shows it. Both
	// compare without case.
	channels:   [dynamic]string,
	categories: [dynamic]string,
}

blocked_destroy :: proc(bl: ^Blocked) {
	for list in ([]^[dynamic]string{&bl.channels, &bl.categories}) {
		for name in list {
			delete(name)
		}
		delete(list^)
	}
}

// The format blocked.json is saved in (see saved.odin). 1 added the version.
BLOCKED_VERSION :: 1

@(private = "file")
blocked_path :: proc() -> (path: string, ok: bool) {
	return state_path("blocked.json")
}

@(private = "file")
Blocked_File :: struct {
	version:    int,
	channels:   []string,
	categories: []string,
}

blocked_load :: proc() -> (bl: Blocked) {
	path, ok := blocked_path()
	if !ok {
		return
	}
	data, _, read := saved_read(path, BLOCKED_VERSION)
	if read != .Read {
		return
	}
	saved: Blocked_File
	if json.unmarshal(data, &saved, allocator = context.temp_allocator) != nil {
		saved_unreadable(path)
		return
	}
	for name in saved.channels {
		blocked_add(&bl, .Channel, name)
	}
	for name in saved.categories {
		blocked_add(&bl, .Category, name)
	}
	return
}

blocked_save :: proc(bl: ^Blocked) {
	path, ok := blocked_path()
	if !ok {
		return
	}
	saved := Blocked_File{BLOCKED_VERSION, bl.channels[:], bl.categories[:]}
	data, err := json.marshal(saved, {pretty = true}, context.temp_allocator)
	if err != nil {
		return
	}
	save_file(path, data)
}

blocked_list :: proc(bl: ^Blocked, kind: Block_Kind) -> ^[dynamic]string {
	return &bl.channels if kind == .Channel else &bl.categories
}

is_blocked :: proc(bl: ^Blocked, kind: Block_Kind, name: string) -> bool {
	if name == "" {
		return false
	}
	for have in blocked_list(bl, kind) {
		if strings.equal_fold(have, name) {
			return true
		}
	}
	return false
}

// Adds `typed` (trimmed; a channel's login lowercased), unless it's blank, not a
// valid login, or already there. Returns whether it was added.
blocked_add :: proc(bl: ^Blocked, kind: Block_Kind, typed: string) -> bool {
	name := strings.trim_space(typed)
	if kind == .Channel {
		name = strings.to_lower(strings.trim_prefix(name, "@"), context.temp_allocator)
		if !valid_login(name) {
			return false
		}
	}
	if name == "" || is_blocked(bl, kind, name) {
		return false
	}
	append(blocked_list(bl, kind), strings.clone(name))
	return true
}

blocked_remove :: proc(bl: ^Blocked, kind: Block_Kind, i: int) {
	list := blocked_list(bl, kind)
	if i < 0 || i >= len(list) {
		return
	}
	delete(list[i])
	ordered_remove(list, i)
}

// Blocks `name`, saves, and takes whatever it covers out of the lists shown.
block :: proc(app: ^App, kind: Block_Kind, name: string) -> bool {
	if !blocked_add(&app.blocked, kind, name) {
		return false
	}
	blocked_save(&app.blocked)
	blocked_apply(app)
	return true
}

// Unblocks one, saves, and has the lists fetched again when next shown, since
// what it hid was dropped from them.
unblock :: proc(app: ^App, kind: Block_Kind, i: int) {
	blocked_remove(&app.blocked, kind, i)
	blocked_save(&app.blocked)
	b := &app.browse
	for l in ([]^Stream_List{&b.following, &b.top, &b.category}) {
		l.last_refresh = -BROWSE_REFRESH_MS
	}
	b.categories_refreshed = -CATEGORIES_REFRESH_MS
	b.offline.refreshed = -OFFLINE_REFRESH_MS
}

// Takes everything blocked out of the lists the browse screen has, releasing
// its pictures.
blocked_apply :: proc(app: ^App) {
	b := &app.browse
	for l in ([]^Stream_List{&b.following, &b.top, &b.category}) {
		stream_list_drop_blocked(app, l)
	}
	categories_drop_blocked(app, &b.top_categories)
	categories_drop_blocked(app, &b.followed_categories)
	categories_drop_blocked(app, &b.category_results)
	offline_drop_blocked(app, &b.offline)
	results_drop_blocked(app)
	if b.view == .Category && is_blocked(&app.blocked, .Category, b.category_name) {
		browse_back(app)
	}
	b.hovered = -1
}

// A stream is hidden for its channel or its category.
stream_blocked :: proc(bl: ^Blocked, s: Stream) -> bool {
	return is_blocked(bl, .Channel, s.user_login) || is_blocked(bl, .Category, s.game_name)
}

stream_list_drop_blocked :: proc(app: ^App, l: ^Stream_List) {
	kept := 0
	for s, i in l.streams {
		if stream_blocked(&app.blocked, s) {
			if i < len(l.thumbnails) {
				image_release(&app.assets.images, l.thumbnails[i])
				delete(l.thumbnails[i])
			}
			destroy_stream(s)
			continue
		}
		l.streams[kept] = s
		if i < len(l.thumbnails) {
			l.thumbnails[kept] = l.thumbnails[i]
		}
		kept += 1
	}
	resize(&l.streams, kept)
	resize(&l.thumbnails, min(kept, len(l.thumbnails)))
}

// Box art stays loaded (see finish_categories_job), so only the names go.
categories_drop_blocked :: proc(app: ^App, categories: ^[dynamic]Category) {
	kept := 0
	for c in categories {
		if is_blocked(&app.blocked, .Category, c.name) {
			destroy_category(c)
			continue
		}
		categories[kept] = c
		kept += 1
	}
	resize(categories, kept)
}

offline_drop_blocked :: proc(app: ^App, o: ^Offline_Follows) {
	kept := 0
	for c in o.channels {
		if is_blocked(&app.blocked, .Channel, c.login) {
			if c.avatar_url != "" {
				image_release(&app.assets.images, c.avatar_url)
			}
			destroy_followed_channel(c)
			continue
		}
		o.channels[kept] = c
		kept += 1
	}
	resize(&o.channels, kept)
}

results_drop_blocked :: proc(app: ^App) {
	b := &app.browse
	kept := 0
	for c in b.results {
		if is_blocked(&app.blocked, .Channel, c.broadcaster_login) {
			if c.thumbnail_url != "" {
				image_release(&app.assets.images, c.thumbnail_url)
			}
			destroy_channel(c)
			continue
		}
		b.results[kept] = c
		kept += 1
	}
	resize(&b.results, kept)
	b.unfollow_armed = 0
}

// One choice in the right-click menu: what it blocks, and what it says.
Block_Item :: struct {
	kind:  Block_Kind,
	// Owned.
	name:  string,
	label: string,
}

// The browse screen's right-click menu, for blocking what was clicked.
Block_Menu :: struct {
	open:  bool,
	// Where it was opened, in pixels.
	at:    [2]f32,
	// Owned.
	items: [dynamic]Block_Item,
	// Set while drawing.
	rects: [dynamic]Rect,
}

block_menu_close :: proc(m: ^Block_Menu) {
	for item in m.items {
		delete(item.name)
		delete(item.label)
	}
	clear(&m.items)
	clear(&m.rects)
	m.open = false
}

block_menu_destroy :: proc(m: ^Block_Menu) {
	block_menu_close(m)
	delete(m.items)
	delete(m.rects)
}

@(private = "file")
block_menu_add :: proc(m: ^Block_Menu, kind: Block_Kind, name, shown: string) {
	if name == "" {
		return
	}
	label := fmt.aprintf("Block %s", shown if shown != "" else name)
	append(&m.items, Block_Item{kind, strings.clone(name), label})
}

// A right-click on the browse screen: a menu for blocking the channel or
// category under the mouse, if there's one.
browse_right_click :: proc(app: ^App, x, y: f32) {
	b := &app.browse
	m := &b.block_menu
	block_menu_close(m)
	i := browse_card_at(b, x, y)
	if i < 0 {
		return
	}
	#partial switch b.view {
	case .Following, .Top, .Category:
		l := browse_list(b, b.view)
		if i < len(l.streams) {
			s := l.streams[i]
			block_menu_add(m, .Channel, s.user_login, s.user_name)
			block_menu_add(m, .Category, s.game_name, s.game_name)
		} else if offline := i - len(l.streams); b.view == .Following && offline < len(b.offline.channels) {
			c := b.offline.channels[offline]
			block_menu_add(m, .Channel, c.login, c.display_name)
		}
	case .Categories:
		if i < len(b.top_categories) {
			block_menu_add(m, .Category, b.top_categories[i].name, b.top_categories[i].name)
		}
	case .Followed_Categories:
		if i < len(b.followed_categories) {
			block_menu_add(m, .Category, b.followed_categories[i].name, b.followed_categories[i].name)
		}
	case .Search:
		if b.search_kind == .Categories {
			if i < len(b.category_results) {
				block_menu_add(m, .Category, b.category_results[i].name, b.category_results[i].name)
			}
			break
		}
		// The rows after "Go to", if it's first, are the results.
		result := i - (search_row_count(b) - len(b.results))
		if result >= 0 && result < len(b.results) {
			c := b.results[result]
			block_menu_add(m, .Channel, c.broadcaster_login, c.display_name)
		}
	}
	m.open = len(m.items) > 0
	m.at = {x, y}
}

// A left click while the menu is open: blocks the item clicked, if one was.
// Any click closes the menu, and goes no further.
block_menu_click :: proc(app: ^App, x, y: f32) -> bool {
	m := &app.browse.block_menu
	if !m.open {
		return false
	}
	for rect, i in m.rects {
		if in_rect(rect, x, y) && i < len(m.items) {
			item := m.items[i]
			name := strings.clone(item.name, context.temp_allocator)
			block_menu_close(m)
			block(app, item.kind, name)
			return true
		}
	}
	block_menu_close(m)
	return true
}

// The menu at the mouse, kept on screen.
draw_block_menu :: proc(app: ^App, screen: Rect) {
	m := &app.browse.block_menu
	clear(&m.rects)
	if !m.open {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	item_h := MENU_ITEM_HEIGHT * scale * r.text_scale
	menu_w := MENU_WIDTH * scale
	for item in m.items {
		menu_w = max(menu_w, text_width(r, .Regular, size, item.label) + 50 * scale)
	}
	menu_w = min(menu_w, screen.w / 2)
	menu_h := item_h * f32(len(m.items))
	menu := Rect{min(m.at.x, screen.w - menu_w), min(m.at.y, screen.h - menu_h), menu_w, menu_h}
	draw_rect(r, {menu.x - scale, menu.y - scale, menu.w + 2 * scale, menu.h + 2 * scale}, USER_CARD_BORDER)
	draw_rect(r, menu, USER_CARD_BACKGROUND)
	for item, i in m.items {
		rect := Rect{menu.x, menu.y + f32(i) * item_h, menu.w, item_h}
		append(&m.rects, rect)
		draw_menu_item(app, rect, fit_text(r, .Regular, size, item.label, menu.w - 40 * scale), false)
	}
}
