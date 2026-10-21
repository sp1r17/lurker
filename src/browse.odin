package app

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// Sizes in logical pixels, scaled by the display scale.
BROWSE_CARD_WIDTH :: 320
BROWSE_GAP :: 16
BROWSE_PADDING :: 20
BROWSE_HEADER_HEIGHT :: 56
BROWSE_TITLE_SIZE :: 24
BROWSE_CARD_TITLE_SIZE :: 17
BROWSE_CARD_TEXT_SIZE :: 16
BROWSE_SCROLL_STEP :: 80
// Thumbnails are fetched at this size; Twitch scales them to order.
THUMBNAIL_SIZE :: [2]int{440, 248}
// Twitch refreshes thumbnails every few minutes; the live list is checked every
// minute while browsing.
BROWSE_REFRESH_MS :: 60_000

BROWSE_BACKGROUND :: Color{0x0e, 0x0e, 0x10, 255}
BROWSE_CARD_HOVER :: Color{0x26, 0x26, 0x2c, 255}
BROWSE_PLACEHOLDER :: Color{0x1f, 0x1f, 0x23, 255}
BROWSE_TEXT :: Color{0xef, 0xef, 0xf1, 255}
BROWSE_DIM_TEXT :: Color{0xad, 0xad, 0xb8, 255}
BROWSE_ACCENT :: Color{0xbf, 0x94, 0xff, 255}
LIVE_RED :: Color{0xeb, 0x04, 0x00, 255}
VIEWERS_BACKGROUND :: Color{0, 0, 0, 180}

Browse_State :: enum {
	// Nothing fetched yet.
	Empty,
	Loading,
	Loaded,
	Failed,
}

// The followed channels that are live, as a grid of cards.
Browse :: struct {
	state:          Browse_State,
	// Owned. Most viewers first.
	streams:        [dynamic]Stream,
	// Owned; each stream's thumbnail URL at the time it was fetched.
	thumbnails:     [dynamic]string,
	// Bumped on every refresh, so thumbnails are fetched anew.
	refresh_count:  int,
	last_refresh:   int,
	scroll:         f32,
	max_scroll:     f32,
	// Set while drawing, parallel to streams: where each card is, in pixels.
	cards:          [dynamic]Rect,
	hovered:        int,
}

browse_destroy :: proc(b: ^Browse) {
	for s in b.streams {
		destroy_stream(s)
	}
	delete(b.streams)
	for url in b.thumbnails {
		delete(url)
	}
	delete(b.thumbnails)
	delete(b.cards)
}

// Fetches the live list if it's due: never fetched, or older than BROWSE_REFRESH_MS.
// Returns ms until the next refresh is due, for the main loop's wait.
browse_tick :: proc(app: ^App) -> (wait_ms: int) {
	b := &app.browse
	if !app.signed_in {
		return -1
	}
	now := app.assets.now_ms
	if b.state == .Loading {
		return -1
	}
	due := b.last_refresh + BROWSE_REFRESH_MS
	if b.state == .Empty || now >= due {
		browse_refresh(app)
		return -1
	}
	return due - now
}

// Empties the list, releasing its thumbnails (after signing out).
browse_clear :: proc(app: ^App) {
	b := &app.browse
	for s in b.streams {
		destroy_stream(s)
	}
	clear(&b.streams)
	for url in b.thumbnails {
		image_release(&app.assets.images, url)
		delete(url)
	}
	clear(&b.thumbnails)
	clear(&b.cards)
	b.state = .Empty
	b.hovered = -1
	b.scroll = 0
}

browse_refresh :: proc(app: ^App) {
	if !app.signed_in || app.browse.state == .Loading {
		return
	}
	app.browse.state = .Loading
	jobs_add(
		&app.assets.jobs,
		run_followed_job,
		Followed_Job{client_id = strings.clone(app.client_id), auth = clone_auth(app.auth)},
	)
}

Followed_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	check:     Auth_Check,
	ok:        bool,
	// Owned.
	streams:   [dynamic]Stream,
}

destroy_followed_job :: proc(p: ^Followed_Job) {
	for s in p.streams {
		destroy_stream(s)
	}
	delete(p.streams)
	delete(p.client_id)
	destroy_auth(p.auth)
}

@(private = "file")
run_followed_job :: proc(job: ^Job) {
	p := &job.payload.(Followed_Job)
	p.check = .Valid
	streams, err := get_followed_streams(p.client_id, p.auth.access_token, p.auth.user_id)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		streams, err = get_followed_streams(p.client_id, p.auth.access_token, p.auth.user_id)
	}
	if err != .None {
		return
	}
	for s in streams {
		append(&p.streams, clone_stream(s))
	}
	p.ok = true
}

// On the main thread: replaces the list, releasing the old thumbnails.
finish_followed_job :: proc(app: ^App, p: ^Followed_Job) {
	b := &app.browse
	b.last_refresh = app.assets.now_ms
	if !p.ok {
		b.state = .Failed if len(b.streams) == 0 else .Loaded
		return
	}
	for s in b.streams {
		destroy_stream(s)
	}
	clear(&b.streams)
	for url in b.thumbnails {
		image_release(&app.assets.images, url)
		delete(url)
	}
	clear(&b.thumbnails)

	b.refresh_count += 1
	for s in p.streams {
		append(&b.streams, s)
		url, _ := strings.replace_all(s.thumbnail_url, "{width}", fmt.tprint(THUMBNAIL_SIZE.x), context.temp_allocator)
		url, _ = strings.replace_all(url, "{height}", fmt.tprint(THUMBNAIL_SIZE.y), context.temp_allocator)
		// Twitch's CDN caches thumbnails; a new query string gets the current one.
		append(&b.thumbnails, fmt.aprintf("%s?r=%d", url, b.refresh_count))
	}
	clear(&p.streams)
	b.state = .Loaded
}

browse_scroll :: proc(b: ^Browse, wheel_y, scale: f32) {
	b.scroll = clamp(b.scroll - wheel_y * BROWSE_SCROLL_STEP * scale, 0, b.max_scroll)
}

// The card under (x, y), or -1.
browse_card_at :: proc(b: ^Browse, x, y: f32) -> int {
	for rect, i in b.cards {
		if in_rect(rect, x, y) {
			return i
		}
	}
	return -1
}

draw_browse :: proc(app: ^App, screen: Rect) {
	a := &app.assets
	r := &a.renderer
	b := &app.browse
	scale := app.scale
	pad := BROWSE_PADDING * scale
	gap := BROWSE_GAP * scale
	draw_rect(r, screen, BROWSE_BACKGROUND)

	// Header: what's shown, and who's signed in.
	header_h := BROWSE_HEADER_HEIGHT * scale
	title_size := BROWSE_TITLE_SIZE * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	title_y := (header_h - line_height(r, .Bold, title_size)) / 2
	x := draw_text(r, .Bold, title_size, pad, title_y, "Following", BROWSE_TEXT)
	if b.state == .Loaded || len(b.streams) > 0 {
		draw_text(
			r,
			.Regular,
			text_size,
			x + 12 * scale,
			(header_h - line_height(r, .Regular, text_size)) / 2,
			fmt.tprintf("%d live", len(b.streams)),
			BROWSE_DIM_TEXT,
		)
	}
	// Window buttons at the far right, like a title bar's.
	controls_left := draw_window_controls(app, screen.w, 0)
	app.sign_in.sign_out = {}
	if app.signed_in {
		// "R to refresh  ·  login  ·  Sign out", with "Sign out" clickable.
		y := (header_h - line_height(r, .Regular, text_size)) / 2
		label := "Sign out"
		lw := text_width(r, .Regular, text_size, label)
		app.sign_in.sign_out = {controls_left - pad - lw, y, lw, line_height(r, .Regular, text_size)}
		hovered := in_rect(app.sign_in.sign_out, app.mouse.x, app.mouse.y)
		draw_text(r, .Regular, text_size, app.sign_in.sign_out.x, y, label, BROWSE_TEXT if hovered else BROWSE_ACCENT)
		hint := fmt.tprintf("R to refresh  ·  %s  ·  ", app.auth.login)
		hw := text_width(r, .Regular, text_size, hint)
		draw_text(r, .Regular, text_size, app.sign_in.sign_out.x - hw, y, hint, BROWSE_DIM_TEXT)
	}

	clear(&b.cards)
	content := Rect{0, header_h, screen.w, screen.h - header_h}
	if !app.signed_in {
		draw_sign_in(app, content)
		return
	}
	message := ""
	switch {
	case b.state == .Empty || (b.state == .Loading && len(b.streams) == 0):
		message = "Loading..."
	case b.state == .Failed:
		message = "Couldn't load the channels you follow. Press R to try again."
	case len(b.streams) == 0:
		message = "None of the channels you follow are live."
	}
	if message != "" {
		draw_centered(r, .Regular, text_size, content, message, BROWSE_DIM_TEXT)
		return
	}

	// Cards in as many columns as fit, stretched to fill the width.
	min_w := BROWSE_CARD_WIDTH * scale
	columns := max(1, int((content.w - 2 * pad + gap) / (min_w + gap)))
	card_w := (content.w - 2 * pad - gap * f32(columns - 1)) / f32(columns)
	thumb_h := card_w * f32(THUMBNAIL_SIZE.y) / f32(THUMBNAIL_SIZE.x)
	card_title_size := BROWSE_CARD_TITLE_SIZE * scale
	lh_title := line_height(r, .Bold, card_title_size)
	lh_text := line_height(r, .Regular, text_size)
	text_pad := 8 * scale
	card_h := thumb_h + text_pad + lh_title + 2 * lh_text + text_pad
	rows := (len(b.streams) + columns - 1) / columns
	total_h := f32(rows) * card_h + f32(max(rows - 1, 0)) * gap + 2 * pad
	b.max_scroll = max(0, total_h - content.h)
	b.scroll = min(b.scroll, b.max_scroll)

	clip_begin(r, content)
	for s, i in b.streams {
		col := i % columns
		row := i / columns
		card := Rect {
			content.x + pad + f32(col) * (card_w + gap),
			content.y + pad + f32(row) * (card_h + gap) - b.scroll,
			card_w,
			card_h,
		}
		append(&b.cards, card)
		if card.y > content.y + content.h || card.y + card.h < content.y {
			continue
		}
		if i == b.hovered {
			draw_rect(r, card, BROWSE_CARD_HOVER)
		}

		thumb := Rect{card.x, card.y, card.w, thumb_h}
		// Thumbnails change every few minutes: not worth keeping on disk.
		image := image_get(&a.images, &a.jobs, b.thumbnails[i], 1, cache = false)
		if image.state == .Ready {
			texture, _ := image_frame(image, a.now_ms)
			draw_image(r, texture, thumb)
		} else {
			draw_rect(r, thumb, BROWSE_PLACEHOLDER)
		}

		// Viewer count over the thumbnail's bottom left, with a red live dot.
		viewers := format_viewers(s.viewer_count)
		vw := text_width(r, .Regular, text_size, viewers)
		dot := 8 * scale
		inset := 6 * scale
		badge := Rect{thumb.x + inset, thumb.y + thumb.h - inset - lh_text - 4 * scale, dot + 12 * scale + vw, lh_text + 4 * scale}
		draw_rect(r, badge, VIEWERS_BACKGROUND)
		draw_rect(r, {badge.x + 5 * scale, badge.y + (badge.h - dot) / 2, dot, dot}, LIVE_RED)
		draw_text(r, .Regular, text_size, badge.x + dot + 9 * scale, badge.y + 2 * scale, viewers, BROWSE_TEXT)

		tx := card.x + text_pad
		tw := card.w - 2 * text_pad
		ty := thumb.y + thumb.h + text_pad
		draw_text_line(a, .Bold, card_title_size, tx, ty, s.title, BROWSE_TEXT, tw)
		ty += lh_title
		draw_text(r, .Regular, text_size, tx, ty, fit_text(r, .Regular, text_size, s.user_name, tw), BROWSE_ACCENT)
		ty += lh_text
		draw_text(r, .Regular, text_size, tx, ty, fit_text(r, .Regular, text_size, s.game_name, tw), BROWSE_DIM_TEXT)
	}
	clip_end(r)
}

draw_centered :: proc(r: ^Renderer, font: Font, size: f32, area: Rect, text: string, color: Color) {
	w := text_width(r, font, size, text)
	h := line_height(r, font, size)
	draw_text(r, font, size, area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, text, color)
}

// "999", "1.2K", "12.3K", "1.5M": Twitch's style.
format_viewers :: proc(n: int) -> string {
	switch {
	case n < 1000:
		return fmt.tprint(n)
	case n < 1_000_000:
		return trim_point_zero(fmt.tprintf("%.1fK", f64(n) / 1000))
	case:
		return trim_point_zero(fmt.tprintf("%.1fM", f64(n) / 1_000_000))
	}
}

@(private = "file")
trim_point_zero :: proc(s: string) -> string {
	if len(s) > 3 && s[len(s) - 3:len(s) - 1] == ".0" {
		return strings.concatenate({s[:len(s) - 3], s[len(s) - 1:]}, context.temp_allocator)
	}
	return s
}

// The text, cut short with "…" if it's wider than max_w. Allocated with the temp
// allocator when cut.
fit_text :: proc(r: ^Renderer, font: Font, size: f32, text: string, max_w: f32) -> string {
	if text_width(r, font, size, text) <= max_w {
		return text
	}
	ellipsis :: "…"
	room := max_w - text_width(r, font, size, ellipsis)
	end := 0
	for i := 0; i < len(text); {
		_, n := utf8.decode_rune_in_string(text[i:])
		if text_width(r, font, size, text[:i + n]) > room {
			break
		}
		i += n
		end = i
	}
	return strings.concatenate({strings.trim_right_space(text[:end]), ellipsis}, context.temp_allocator)
}
