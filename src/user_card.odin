package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

USER_CARD_WIDTH :: 380
USER_CARD_AVATAR :: 64
// The tallest the card's message list grows, in logical pixels; it scrolls past that.
USER_CARD_LIST_HEIGHT :: 360
USER_CARD_BACKGROUND :: Color{0x18, 0x18, 0x1b, 250}
USER_CARD_BORDER :: Color{0x3a, 0x3a, 0x40, 255}

// A user's Twitch account, from Helix /users. Strings are owned.
User_Info :: struct {
	id:                string,
	login:             string,
	display_name:      string,
	description:       string,
	profile_image_url: string,
	created_at:        string,
}

destroy_user_info :: proc(u: User_Info) {
	delete(u.id)
	delete(u.login)
	delete(u.display_name)
	delete(u.description)
	delete(u.profile_image_url)
	delete(u.created_at)
}

User_Card_State :: enum {
	Loading,
	Loaded,
	// Couldn't look the account up; recent messages still show.
	Unavailable,
}

// Chatterino's user popup: who someone is, and what they've said here.
User_Card :: struct {
	open:     bool,
	// The pane whose chat it was opened from, by ID.
	pane:     int,
	login:    string,
	state:    User_Card_State,
	info:     User_Info,
	// Where it was opened from (y in pixels), and where it's drawn.
	anchor_y: f32,
	rect:     Rect,
	// Bumped per card, so a lookup for an earlier one is ignored.
	request:  int,
	// From the last draw: the links to their videos and to ignore them, the
	// moderation buttons, the list of messages and how far it's scrolled up (and can
	// be), where names, emotes and links are in it, and the delete buttons.
	videos_link: Rect,
	ignore_link: Rect,
	mod_links:   [len(USER_CARD_MOD_ACTIONS)]Rect,
	list_rect:   Rect,
	scroll:      f32,
	max_scroll:  f32,
	hits:        Chat_View,
	delete_hits: [dynamic]Card_Delete_Hit,
}

Card_Delete_Hit :: struct {
	rect:  Rect,
	// The message, as an index into the pane's messages and its ID (checked on a
	// click, in case the messages changed since). The ID points into it.
	index: int,
	id:    string,
}

@(rodata)
USER_CARD_MOD_ACTIONS := [?]struct {
	label:   string,
	action:  Mod_Action,
	seconds: int,
}{{"1m", .Timeout, 60}, {"10m", .Timeout, 600}, {"1h", .Timeout, 3600}, {"1d", .Timeout, 86400}, {"Ban", .Ban, 0}, {"Unban", .Unban, 0}}

user_card_open :: proc(app: ^App, p: ^Chat_Pane, login: string, anchor_y: f32) {
	c := &app.watch.card
	user_card_close(app)
	c.open = true
	c.pane = p.id
	c.login = strings.clone(login)
	c.anchor_y = anchor_y
	c.request += 1
	// The login goes into a request URL; one from a malformed message mustn't.
	if !app.signed_in || !valid_login(login) {
		c.state = .Unavailable
		return
	}
	c.state = .Loading
	jobs_add(
		&app.assets.jobs,
		run_user_job,
		User_Job{client_id = strings.clone(app.client_id), auth = clone_auth(app.auth), login = strings.clone(login), request = c.request},
	)
}

user_card_close :: proc(app: ^App) {
	c := &app.watch.card
	if !c.open {
		return
	}
	delete(c.login)
	destroy_user_info(c.info)
	chat_view_destroy(&c.hits)
	delete(c.delete_hits)
	request := c.request
	c^ = {}
	c.request = request
}

User_Job :: struct {
	client_id: string,
	auth:      Auth,
	login:     string,
	request:   int,
	ok:        bool,
	info:      User_Info,
}

destroy_user_job :: proc(p: ^User_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.login)
	destroy_user_info(p.info)
}

@(private = "file")
run_user_job :: proc(job: ^Job) {
	p := &job.payload.(User_Job)
	body, err := helix_get(p.client_id, p.auth.access_token, fmt.tprintf("/users?login=%s", p.login))
	if err != .None {
		return
	}
	p.info, p.ok = parse_user(body)
}

// The first user in a Helix /users response, owned.
parse_user :: proc(body: []byte) -> (u: User_Info, ok: bool) {
	Response :: struct {
		data: []User_Info,
	}
	r: Response
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil || len(r.data) == 0 {
		return {}, false
	}
	d := r.data[0]
	return {
			id = strings.clone(d.id),
			login = strings.clone(d.login),
			display_name = strings.clone(d.display_name),
			description = strings.clone(d.description),
			profile_image_url = strings.clone(d.profile_image_url),
			created_at = strings.clone(d.created_at),
		},
		true
}

finish_user_job :: proc(app: ^App, p: ^User_Job) {
	c := &app.watch.card
	if app.screen != .Watch || !c.open || p.request != c.request {
		return
	}
	if !p.ok {
		c.state = .Unavailable
		return
	}
	c.info, p.info = p.info, {}
	c.state = .Loaded
}

// Drawn beside the chat, over the video, level with the name that was clicked:
// who they are, buttons to moderate them, and everything they've said in this chat.
draw_user_card :: proc(app: ^App) {
	c := &app.watch.card
	if !c.open {
		return
	}
	p := find_pane(app, c.pane)
	if p == nil {
		return
	}
	a := &app.assets
	r := &a.renderer
	scale := app.scale
	pad := 12 * scale
	gap := CHAT_MESSAGE_GAP * scale
	small := BROWSE_CARD_TEXT_SIZE * scale
	lh_small := line_height(r, .Regular, small)
	avatar := USER_CARD_AVATAR * scale
	card_w := USER_CARD_WIDTH * scale
	moderating := pane_moderating(p) && c.login != app.auth.login

	// Their messages here, oldest first, and their colour from the latest.
	theirs := make([dynamic]int, context.temp_allocator)
	color := CHAT_TEXT
	for &m, i in p.view.messages {
		if m.login == c.login && m.kind != .System {
			append(&theirs, i)
			color = m.color
		}
	}
	// Each message has how long ago it was sent at its left.
	time_w := text_width(r, .Regular, small, "00m") + pad / 2
	text_w := card_w - 2 * pad - time_w
	total: f32
	for i in theirs {
		m := &p.view.messages[i]
		total += message_layout_into(a, &p.emotes, m, &m.card_layout, scale, text_w).height + gap
	}

	header_h := avatar + 2 * pad
	// No line for a bio they don't have.
	bio_h := lh_small + pad if c.state != .Loaded || c.info.description != "" else 0
	mod_h := lh_small + pad if moderating else 0
	label_h := lh_small + pad / 2
	foot_h := pad + lh_small + pad
	fixed_h := header_h + bio_h + mod_h + label_h + foot_h
	list_h := clamp(total, line_height(r, .Regular, CHAT_FONT_SIZE * scale), USER_CARD_LIST_HEIGHT * scale)
	list_h = max(0, min(list_h, p.rect.h - 16 * scale - fixed_h))
	card_h := fixed_h + list_h
	// Beside the pane, over the video or the split to its left.
	x := max(8 * scale, p.rect.x - card_w - 8 * scale)
	y := clamp(c.anchor_y - 24 * scale, 8 * scale, p.rect.h - card_h - 8 * scale)
	c.rect = {x, y, card_w, card_h}
	draw_rect(r, c.rect, USER_CARD_BORDER)
	draw_rect(r, {x + scale, y + scale, card_w - 2 * scale, card_h - 2 * scale}, USER_CARD_BACKGROUND)

	// Avatar, name, login.
	avatar_rect := Rect{x + pad, y + pad, avatar, avatar}
	image: ^Image
	if c.state == .Loaded && c.info.profile_image_url != "" {
		image = image_get(&a.images, &a.jobs, c.info.profile_image_url, 1)
	}
	if image != nil && image.state == .Ready {
		texture, _ := image_frame(image, a.now_ms)
		draw_image(r, texture, avatar_rect)
	} else {
		draw_rect(r, avatar_rect, BROWSE_PLACEHOLDER)
	}
	tx := avatar_rect.x + avatar + pad
	tw := x + card_w - pad - tx
	name := c.info.display_name if c.state == .Loaded && c.info.display_name != "" else c.login
	name_size := 20 * scale
	draw_text(r, .Bold, name_size, tx, y + pad, fit_text(r, .Bold, name_size, name, tw), color)
	ty := y + pad + line_height(r, .Bold, name_size)
	switch c.state {
	case .Loading:
		draw_text(r, .Regular, small, tx, ty, "Loading...", BROWSE_DIM_TEXT)
	case .Unavailable:
		draw_text(r, .Regular, small, tx, ty, c.login, BROWSE_DIM_TEXT)
	case .Loaded:
		draw_text(r, .Regular, small, tx, ty, c.info.login, BROWSE_DIM_TEXT)
		if len(c.info.created_at) >= 10 {
			created := fmt.tprintf("Account created %s", c.info.created_at[:10])
			draw_text(r, .Regular, small, tx, ty + lh_small, created, BROWSE_DIM_TEXT)
		}
	}

	// Their bio, on one line.
	ty = y + header_h
	if c.state == .Loaded && c.info.description != "" {
		draw_text_line(a, .Regular, small, x + pad, ty, c.info.description, CHAT_TEXT, card_w - 2 * pad)
	}
	ty += bio_h

	// Timeouts and bans, for moderators.
	c.mod_links = {}
	if moderating {
		lx := x + pad
		draw_text(r, .Regular, small, lx, ty, "Timeout", BROWSE_DIM_TEXT)
		lx += text_width(r, .Regular, small, "Timeout") + pad / 2
		for action, i in USER_CARD_MOD_ACTIONS {
			if action.action == .Ban {
				lx += pad / 2
			}
			lw := text_width(r, .Bold, small, action.label)
			c.mod_links[i] = {lx, ty, lw, lh_small}
			hovered := in_rect(c.mod_links[i], app.mouse.x, app.mouse.y)
			draw_text(r, .Bold, small, lx, ty, action.label, BROWSE_TEXT if hovered else BROWSE_ACCENT)
			lx += lw + pad * 0.75
		}
		ty += mod_h
	}

	label := fmt.tprintf("Messages here (%d)", len(theirs)) if len(theirs) > 0 else "Messages here"
	draw_text(r, .Bold, small, x + pad, ty, label, BROWSE_DIM_TEXT)
	ty += label_h

	// The messages, newest at the bottom, scrolled up by c.scroll.
	c.list_rect = {x + scale, ty, card_w - 2 * scale, list_h}
	c.max_scroll = max(0, total - list_h)
	c.scroll = clamp(c.scroll, 0, c.max_scroll)
	clear(&c.hits.name_hits)
	clear(&c.hits.image_hits)
	clear(&c.hits.message_hits)
	clear(&c.hits.link_hits)
	clear(&c.delete_hits)
	if len(theirs) == 0 {
		draw_text(r, .Regular, CHAT_FONT_SIZE * scale, x + pad, ty, "None in this chat yet.", CHAT_SYSTEM_TEXT)
	}
	clip_begin(r, c.list_rect)
	now_ms := time.to_unix_nanoseconds(time.now()) / 1e6
	bottom := c.list_rect.y + list_h + c.scroll
	#reverse for i in theirs {
		m := &p.view.messages[i]
		l := &m.card_layout
		top := bottom - l.height
		bottom = top - gap
		if top > c.list_rect.y + list_h {
			continue
		}
		if top + l.height < c.list_rect.y {
			break
		}
		row := Rect{c.list_rect.x, top - gap / 2, c.list_rect.w, l.height + gap}
		hovered := in_rect(row, app.mouse.x, app.mouse.y) && in_rect(c.list_rect, app.mouse.x, app.mouse.y)
		if m.mention {
			draw_rect(r, row, CHAT_MENTION_BACKGROUND)
		} else if hovered {
			draw_rect(r, row, MENU_HOVER)
		}
		draw_text(r, .Regular, small, x + pad, top, time_ago(now_ms - m.sent_ms), CHAT_SYSTEM_TEXT)
		draw_message(a, &c.hits, m, l, x + pad + time_w, top)
		// Deleting it, for moderators: × at its right while hovered.
		if moderating && hovered && m.id != "" && !m.deleted {
			button := Rect{row.x + row.w - row.h, row.y, row.h, min(row.h, lh_small + gap)}
			button.w = button.h
			button.x = row.x + row.w - button.w
			over := in_rect(button, app.mouse.x, app.mouse.y)
			draw_rect(r, button, CHAT_MENTION_BACKGROUND if over else CHAT_HEADER)
			draw_centered(r, .Bold, small, button, "×", CHAT_TEXT)
			append(&c.delete_hits, Card_Delete_Hit{button, i, m.id})
		}
	}
	clip_end(r)

	ty = y + card_h - pad - lh_small
	// Ignoring them at the left of the last line, their videos at the right.
	ignore := "Unignore" if chat_ignored(app, c.login) else "Ignore"
	c.ignore_link = {x + pad, ty, text_width(r, .Bold, small, ignore), lh_small}
	ignore_hovered := in_rect(c.ignore_link, app.mouse.x, app.mouse.y)
	draw_text(r, .Bold, small, c.ignore_link.x, ty, ignore, BROWSE_TEXT if ignore_hovered else BROWSE_ACCENT)
	videos := "Videos ›"
	lw := text_width(r, .Bold, small, videos)
	c.videos_link = {x + card_w - pad - lw, ty, lw, lh_small}
	hovered := in_rect(c.videos_link, app.mouse.x, app.mouse.y)
	draw_text(r, .Bold, small, c.videos_link.x, ty, videos, BROWSE_TEXT if hovered else BROWSE_ACCENT)
}

// "now", "5m", "3h", "2d": how long ago, for the user card.
time_ago :: proc(ms: i64) -> string {
	seconds := ms / 1000
	switch {
	case seconds < 60:
		return "now"
	case seconds < 3600:
		return fmt.tprintf("%dm", seconds / 60)
	case seconds < 86400:
		return fmt.tprintf("%dh", seconds / 3600)
	case:
		return fmt.tprintf("%dd", seconds / 86400)
	}
}

// Scrolls the card's messages, if (x, y) is over the card.
user_card_scroll :: proc(app: ^App, x, y, wheel_y: f32) -> bool {
	c := &app.watch.card
	if !c.open || !in_rect(c.rect, x, y) {
		return false
	}
	c.scroll = clamp(c.scroll + wheel_y * CHAT_SCROLL_STEP * app.scale, 0, c.max_scroll)
	return true
}

// Handles a click on the card at (x, y).
user_card_click :: proc(app: ^App, x, y: f32) {
	c := &app.watch.card
	p := find_pane(app, c.pane)
	if p == nil {
		return
	}
	switch {
	case in_rect(c.videos_link, x, y):
		watch_open_videos(app, c.login, c.info.display_name if c.state == .Loaded else "")
		return
	case in_rect(c.ignore_link, x, y):
		if valid_login(c.login) && !chat_unignore(app, c.login) {
			chat_ignore(app, c.login)
		}
		return
	}
	user_id := c.info.id if c.state == .Loaded else ""
	for link, i in c.mod_links {
		if link.w > 0 && in_rect(link, x, y) {
			action := USER_CARD_MOD_ACTIONS[i]
			mod_request(app, p, action.action, login = c.login, user_id = user_id, seconds = action.seconds)
			return
		}
	}
	for hit in c.delete_hits {
		if in_rect(hit.rect, x, y) && hit.index < len(p.view.messages) && p.view.messages[hit.index].id == hit.id {
			mod_request(app, p, .Delete, login = c.login, message_id = hit.id)
			return
		}
	}
	if url, found := chat_view_link_at(&c.hits, x, y); found {
		open_url(url)
	}
}

// A message's text with emotes as their names, allocated with the temp allocator.
message_plain_text :: proc(m: ^Chat_Message) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for f, i in m.fragments {
		if i > 0 {
			strings.write_byte(&sb, ' ')
		}
		strings.write_string(&sb, strings.trim_space(f.text))
	}
	return strings.to_string(sb)
}
