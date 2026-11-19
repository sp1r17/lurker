package app

import "core:encoding/json"
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
