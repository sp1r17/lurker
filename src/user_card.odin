package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"

USER_CARD_WIDTH :: 340
USER_CARD_AVATAR :: 64
USER_CARD_RECENT :: 10
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
	// The link to their videos, from the last draw.
	videos_link: Rect,
}

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

// Drawn beside the chat, over the video, level with the name that was clicked.
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
	size := CHAT_FONT_SIZE * scale
	small := BROWSE_CARD_TEXT_SIZE * scale
	lh := line_height(r, .Regular, size)
	lh_small := line_height(r, .Regular, small)
	avatar := USER_CARD_AVATAR * scale

	// Their messages here, newest last, and their colour from the latest.
	recent := make([dynamic]^Chat_Message, context.temp_allocator)
	color := CHAT_TEXT
	for i := len(p.view.messages) - 1; i >= 0 && len(recent) < USER_CARD_RECENT; i -= 1 {
		m := &p.view.messages[i]
		if m.login == c.login && m.kind != .System {
			if len(recent) == 0 {
				color = m.color
			}
			inject_at(&recent, 0, m)
		}
	}

	card_w := USER_CARD_WIDTH * scale
	header_h := avatar + 2 * pad
	recent_h := lh_small + f32(max(len(recent), 1)) * lh + pad
	card_h := header_h + lh_small + pad + recent_h + lh_small + pad
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
	ty += lh_small + pad

	// Recent messages, one line each.
	draw_text(r, .Bold, small, x + pad, ty, "Recent messages", BROWSE_DIM_TEXT)
	ty += lh_small
	if len(recent) == 0 {
		draw_text(r, .Regular, size, x + pad, ty, "None in this chat yet.", CHAT_SYSTEM_TEXT)
	}
	for m in recent {
		text := message_plain_text(m)
		text_color := CHAT_TEXT
		if m.deleted {
			text_color = CHAT_SYSTEM_TEXT
		}
		draw_text_line(a, .Regular, size, x + pad, ty, text, text_color, card_w - 2 * pad)
		ty += lh
	}
	ty = y + card_h - pad - lh_small
	draw_text(r, .Regular, small, x + pad, ty, "Esc or click outside to close", CHAT_SYSTEM_TEXT)
	// Their videos, at the right of that line.
	label := "Videos ›"
	lw := text_width(r, .Bold, small, label)
	c.videos_link = {x + card_w - pad - lw, ty, lw, lh_small}
	hovered := in_rect(c.videos_link, app.mouse.x, app.mouse.y)
	draw_text(r, .Bold, small, c.videos_link.x, ty, label, BROWSE_TEXT if hovered else BROWSE_ACCENT)
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
