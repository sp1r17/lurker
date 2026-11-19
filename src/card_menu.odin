package app

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

Card_Action :: enum {
	Follow_Channel,
	Follow_Category,
	Notify_Channel,
	Copy_Link,
	Block_Channel,
	Block_Category,
}

// The browse screen's right-click menu, for the card clicked: following or
// unfollowing its channel and category, its channel's live notifications and
// link, and blocking them.
Card_Menu :: struct {
	open:           bool,
	// Where it was opened, in pixels.
	at:             [2]f32,
	// What the card is; "" for none. Owned.
	login:          string,
	channel_name:   string,
	category:       string,
	// The channel is live: following it then isn't announced as going live.
	live:           bool,
	// Whether they're followed, looked up when it opens: until then, the follow
	// items wait. Owned.
	follows:        Card_Follows,
	// Bumped at each opening, so a lookup for an earlier one is dropped.
	id:             int,
	// Unfollowing a channel takes a second click, since it loses the follow's
	// date (as the follow buttons do).
	unfollow_armed: bool,
	// Set while drawing: each item's place and what it does.
	rects:          [len(Card_Action)]Rect,
	actions:        [len(Card_Action)]Card_Action,
	count:          int,
}

card_menu_close :: proc(m: ^Card_Menu) {
	delete(m.login)
	delete(m.channel_name)
	delete(m.category)
	destroy_card_follows(m.follows)
	id := m.id
	m^ = {}
	m.id = id
}

card_menu_destroy :: proc(m: ^Card_Menu) {
	card_menu_close(m)
}

@(private = "file")
destroy_card_follows :: proc(f: Card_Follows) {
	delete(f.user_id)
	delete(f.game_id)
}

// A right-click on the browse screen: the menu for the card under the mouse, if
// there's one, and a lookup of whether its channel and category are followed.
browse_right_click :: proc(app: ^App, x, y: f32) {
	b := &app.browse
	m := &b.card_menu
	card_menu_close(m)
	i := browse_card_at(b, x, y)
	if i < 0 {
		return
	}
	login, name, category: string
	live := false
	#partial switch b.view {
	case .Following, .Top, .Category:
		l := browse_list(b, b.view)
		if i < len(l.streams) {
			s := l.streams[i]
			login, name, category, live = s.user_login, s.user_name, s.game_name, true
		} else if offline := i - len(l.streams); b.view == .Following && offline < len(b.offline.channels) {
			c := b.offline.channels[offline]
			login, name = c.login, c.display_name
		}
	case .Categories:
		if i < len(b.top_categories) {
			category = b.top_categories[i].name
		}
	case .Followed_Categories:
		if i < len(b.followed_categories) {
			category = b.followed_categories[i].name
		}
	case .Search:
		if b.search_kind == .Categories {
			if i < len(b.category_results) {
				category = b.category_results[i].name
			}
			break
		}
		// The rows after "Go to", if it's first, are the results.
		result := i - (search_row_count(b) - len(b.results))
		if result >= 0 && result < len(b.results) {
			c := b.results[result]
			login, name, live = c.broadcaster_login, c.display_name, c.is_live
		}
	}
	if login == "" && category == "" {
		return
	}
	m.open = true
	m.at = {x, y}
	m.id += 1
	m.login = strings.clone(login)
	m.channel_name = strings.clone(name if name != "" else login)
	m.category = strings.clone(category)
	m.live = live
	jobs_add(
		&app.assets.jobs,
		run_card_follows_job,
		Card_Follows_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth),
			login = strings.clone(login),
			category = strings.clone(category),
			menu = m.id,
		},
	)
}

// Looks up whether the card menu's channel and category are followed.
Card_Follows_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	login:     string,
	category:  string,
	// The Card_Menu.id it's for.
	menu:      int,
	// Owned, if found.
	follows:   Card_Follows,
	check:     Auth_Check,
	ok:        bool,
}

destroy_card_follows_job :: proc(p: ^Card_Follows_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.login)
	delete(p.category)
	destroy_card_follows(p.follows)
}

@(private = "file")
run_card_follows_job :: proc(job: ^Job) {
	p := &job.payload.(Card_Follows_Job)
	p.check = .Valid
	f, err := get_card_follows(p.client_id, p.auth.access_token, p.login, p.category)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		f, err = get_card_follows(p.client_id, p.auth.access_token, p.login, p.category)
	}
	if err != .None {
		return
	}
	p.follows = f
	p.follows.user_id = strings.clone(f.user_id)
	p.follows.game_id = strings.clone(f.game_id)
	p.ok = true
}

finish_card_follows_job :: proc(app: ^App, p: ^Card_Follows_Job) {
	apply_auth_check(app, p.check, p.auth)
	m := &app.browse.card_menu
	if !p.ok || !m.open || m.id != p.menu {
		return
	}
	destroy_card_follows(m.follows)
	m.follows, p.follows = p.follows, {}
}

// Follows or unfollows a category, from the card menu.
Category_Follow_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	game_id:   string,
	follow:    bool,
	check:     Auth_Check,
	ok:        bool,
}

destroy_category_follow_job :: proc(p: ^Category_Follow_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.game_id)
}

@(private = "file")
run_category_follow_job :: proc(job: ^Job) {
	p := &job.payload.(Category_Follow_Job)
	p.check = .Valid
	err := set_category_follow(p.client_id, p.auth.access_token, p.game_id, p.follow)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		err = set_category_follow(p.client_id, p.auth.access_token, p.game_id, p.follow)
	}
	p.ok = err == .None
}

finish_category_follow_job :: proc(app: ^App, p: ^Category_Follow_Job) {
	apply_auth_check(app, p.check, p.auth)
	if !p.ok {
		return
	}
	b := &app.browse
	// Gone from the Followed list at once; a new follow shows when it's fetched
	// again, which the next look at the categories does.
	if !p.follow {
		for c, i in b.followed_categories {
			if c.id == p.game_id {
				destroy_category(c)
				ordered_remove(&b.followed_categories, i)
				break
			}
		}
	}
	b.categories_refreshed = -CATEGORIES_REFRESH_MS
}

// A left click while the menu is open: does what the item clicked does, if one
// was. Any click closes the menu, but for one on a follow item still waiting for
// its lookup, or the first on "Unfollow"; and goes no further.
card_menu_click :: proc(app: ^App, x, y: f32) -> bool {
	m := &app.browse.card_menu
	if !m.open {
		return false
	}
	for rect, i in m.rects[:m.count] {
		if !in_rect(rect, x, y) {
			continue
		}
		switch m.actions[i] {
		case .Follow_Channel:
			state := m.follows.channel
			if state == .Unknown {
				return true
			}
			if state == .Following && !m.unfollow_armed {
				m.unfollow_armed = true
				return true
			}
			follow_from_menu(app, m.login, m.follows.user_id, state == .Not_Following, m.live)
		case .Follow_Category:
			state := m.follows.category
			if state == .Unknown {
				return true
			}
			jobs_add(
				&app.assets.jobs,
				run_category_follow_job,
				Category_Follow_Job {
					client_id = strings.clone(app.client_id),
					auth = clone_auth(app.auth),
					game_id = strings.clone(m.follows.game_id),
					follow = state == .Not_Following,
				},
			)
		case .Notify_Channel:
			notify_toggle(app, m.login)
		case .Copy_Link:
			link := strings.clone_to_cstring(fmt.tprintf("https://www.twitch.tv/%s", m.login), context.temp_allocator)
			_ = sdl.SetClipboardText(link)
		case .Block_Channel:
			block(app, .Channel, strings.clone(m.login, context.temp_allocator))
		case .Block_Category:
			block(app, .Category, strings.clone(m.category, context.temp_allocator))
		}
		break
	}
	card_menu_close(m)
	return true
}

// The menu at the mouse, kept on screen: the follow items, a divider, then the
// block items.
draw_card_menu :: proc(app: ^App, screen: Rect) {
	m := &app.browse.card_menu
	m.rects = {}
	m.count = 0
	if !m.open {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	item_h := MENU_ITEM_HEIGHT * scale * r.text_scale
	divider := 9 * scale

	labels: [len(Card_Action)]string
	add :: proc(m: ^Card_Menu, labels: ^[len(Card_Action)]string, action: Card_Action, label: string) {
		m.actions[m.count] = action
		labels[m.count] = label
		m.count += 1
	}
	if m.login != "" {
		label := fmt.tprintf("Follow %s", m.channel_name)
		switch {
		case m.unfollow_armed:
			label = fmt.tprintf("Unfollow %s? Click again", m.channel_name)
		case m.follows.channel == .Following:
			label = fmt.tprintf("Unfollow %s", m.channel_name)
		}
		add(m, &labels, .Follow_Channel, label)
	}
	if m.category != "" {
		verb := "Unfollow" if m.follows.category == .Following else "Follow"
		add(m, &labels, .Follow_Category, fmt.tprintf("%s %s", verb, m.category))
	}
	if m.login != "" {
		l := &app.layout
		label: string
		switch {
		case l.notify_only && notify_wanted(l, m.login):
			label = fmt.tprintf("Stop notifying when %s goes live", m.channel_name)
		case l.notify_only:
			label = fmt.tprintf("Notify when %s goes live", m.channel_name)
		case notify_wanted(l, m.login):
			label = fmt.tprintf("Mute %s's live notifications", m.channel_name)
		case:
			label = fmt.tprintf("Unmute %s's live notifications", m.channel_name)
		}
		add(m, &labels, .Notify_Channel, label)
		add(m, &labels, .Copy_Link, "Copy link")
	}
	follow_items := m.count
	if m.login != "" {
		add(m, &labels, .Block_Channel, fmt.tprintf("Block %s", m.channel_name))
	}
	if m.category != "" {
		add(m, &labels, .Block_Category, fmt.tprintf("Block %s", m.category))
	}

	menu_w := MENU_WIDTH * scale
	for label in labels[:m.count] {
		menu_w = max(menu_w, text_width(r, .Bold, size, label) + 50 * scale)
	}
	menu_w = min(menu_w, screen.w / 2)
	menu_h := item_h * f32(m.count) + divider
	menu := Rect{min(m.at.x, screen.w - menu_w), min(m.at.y, screen.h - menu_h), menu_w, menu_h}
	hidden := menu_hover_begin(app, menu)
	defer menu_hover_end(app, hidden)
	draw_rect(r, {menu.x - scale, menu.y - scale, menu.w + 2 * scale, menu.h + 2 * scale}, USER_CARD_BORDER)
	draw_rect(r, menu, USER_CARD_BACKGROUND)
	y := menu.y
	for i in 0 ..< m.count {
		if i == follow_items {
			draw_rect(r, {menu.x + 12 * scale, y + divider / 2, menu.w - 24 * scale, scale}, USER_CARD_BORDER)
			y += divider
		}
		rect := Rect{menu.x, y, menu.w, item_h}
		m.rects[i] = rect
		y += item_h
		color := BROWSE_TEXT
		#partial switch m.actions[i] {
		case .Follow_Channel:
			if m.follows.channel == .Unknown {
				color = BROWSE_DIM_TEXT
			} else if m.unfollow_armed {
				color = LIVE_RED
			}
		case .Follow_Category:
			if m.follows.category == .Unknown {
				color = BROWSE_DIM_TEXT
			}
		}
		draw_menu_item(app, rect, fit_text(r, .Regular, size, labels[i], menu.w - 40 * scale), false, color)
	}
	// "Unfollow?" waits for a second click only while the mouse stays on it.
	for i in 0 ..< m.count {
		if m.actions[i] == .Follow_Channel {
			m.unfollow_armed &&= in_rect(m.rects[i], app.mouse.x, app.mouse.y)
		}
	}
}
