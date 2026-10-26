package app

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

// Who's offline changes slowly, and finding out takes a request per 100 follows.
OFFLINE_REFRESH_MS :: 5 * 60_000
OFFLINE_TILE_WIDTH :: 260
OFFLINE_AVATAR :: 44

// The followed channels that aren't live, below the live ones on the Following
// tab, most recently live first.
Offline_Follows :: struct {
	state:     Browse_State,
	// Owned.
	channels:  [dynamic]Followed_Channel,
	refreshed: int,
}

offline_destroy :: proc(app: ^App, o: ^Offline_Follows) {
	offline_clear(app, o)
	delete(o.channels)
}

// Forgets the list, releasing the pictures (after signing out).
offline_clear :: proc(app: ^App, o: ^Offline_Follows) {
	for c in o.channels {
		if c.avatar_url != "" && app != nil {
			image_release(&app.assets.images, c.avatar_url)
		}
		destroy_followed_channel(c)
	}
	clear(&o.channels)
	o.state = .Empty
	o.refreshed = 0
}

Offline_Follows_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	check:     Auth_Check,
	ok:        bool,
	// Owned.
	channels:  [dynamic]Followed_Channel,
}

destroy_offline_follows_job :: proc(p: ^Offline_Follows_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	for c in p.channels {
		destroy_followed_channel(c)
	}
	delete(p.channels)
}

// Looks up who's offline if it's never been done or is OFFLINE_REFRESH_MS old,
// or now with `force` (R).
offline_refresh :: proc(app: ^App, force := false) {
	o := &app.browse.offline
	if !app.signed_in || o.state == .Loading {
		return
	}
	if !force && o.state != .Empty && app.assets.now_ms < o.refreshed + OFFLINE_REFRESH_MS {
		return
	}
	o.state = .Loading
	jobs_add(
		&app.assets.jobs,
		run_offline_follows_job,
		Offline_Follows_Job{client_id = strings.clone(app.client_id), auth = clone_auth(app.auth)},
	)
}

@(private = "file")
run_offline_follows_job :: proc(job: ^Job) {
	p := &job.payload.(Offline_Follows_Job)
	fetch :: proc(p: ^Offline_Follows_Job) -> (channels: []Followed_Channel, err: Twitch_Error) {
		logins := get_followed_logins(p.client_id, p.auth.access_token, p.auth.user_id) or_return
		return get_channel_status(p.client_id, p.auth.access_token, logins)
	}
	p.check = .Valid
	channels, err := fetch(p)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		channels, err = fetch(p)
	}
	if err != .None {
		return
	}
	for c in channels {
		if !c.live {
			append(&p.channels, clone_followed_channel(c))
		}
	}
	sort_by_last_live(p.channels[:])
	p.ok = true
}

// Most recently live first; channels that never streamed last.
sort_by_last_live :: proc(channels: []Followed_Channel) {
	slice.stable_sort_by(channels, proc(a, b: Followed_Channel) -> bool {
		if (a.last_live == "") != (b.last_live == "") {
			return b.last_live == ""
		}
		// Up to the seconds, the times compare as text.
		return a.last_live[:min(19, len(a.last_live))] > b.last_live[:min(19, len(b.last_live))]
	})
}

finish_offline_follows_job :: proc(app: ^App, p: ^Offline_Follows_Job) {
	apply_auth_check(app, p.check, p.auth)
	o := &app.browse.offline
	o.refreshed = app.assets.now_ms
	if !p.ok || !app.signed_in {
		o.state = .Failed if len(o.channels) == 0 else .Loaded
		return
	}
	// Pictures still shown stay loaded.
	for old in o.channels {
		kept := false
		for c in p.channels {
			kept ||= c.avatar_url == old.avatar_url
		}
		if !kept && old.avatar_url != "" {
			image_release(&app.assets.images, old.avatar_url)
		}
		destroy_followed_channel(old)
	}
	clear(&o.channels)
	append(&o.channels, ..p.channels[:])
	clear(&p.channels)
	offline_drop_blocked(app, o)
	o.state = .Loaded
}

// "Live 5 hours ago", from an RFC 3339 time; "Not live recently" without one.
format_last_live :: proc(started_at: string, now: time.Time) -> string {
	// GraphQL's times have microseconds, which the parser refuses; minutes do.
	whole := started_at
	if len(whole) > 19 && whole[19] == '.' {
		whole = strings.concatenate({whole[:19], "Z"}, context.temp_allocator)
	}
	started, consumed := time.rfc3339_to_time_utc(whole)
	if started_at == "" || consumed == 0 {
		return "Not live recently"
	}
	minutes := max(0, int(time.duration_minutes(time.diff(started, now))))
	unit, n := "minute", minutes
	switch {
	case minutes >= 60 * 24 * 365:
		unit, n = "year", minutes / (60 * 24 * 365)
	case minutes >= 60 * 24 * 30:
		unit, n = "month", minutes / (60 * 24 * 30)
	case minutes >= 60 * 24:
		unit, n = "day", minutes / (60 * 24)
	case minutes >= 60:
		unit, n = "hour", minutes / 60
	}
	if n <= 1 && unit == "minute" {
		return "Live just now"
	}
	return fmt.tprintf("Live %d %s%s ago", n, unit, "" if n == 1 else "s")
}

// The height draw_offline_section takes for `width`, to scroll by.
offline_section_height :: proc(app: ^App, width: f32) -> f32 {
	o := &app.browse.offline
	if len(o.channels) == 0 {
		return 0
	}
	heading_h, tile_h, columns := offline_metrics(app, width)
	rows := (len(o.channels) + columns - 1) / columns
	gap := BROWSE_GAP * app.scale
	return heading_h + f32(rows) * (tile_h + gap)
}

@(private = "file")
offline_metrics :: proc(app: ^App, width: f32) -> (heading_h, tile_h: f32, columns: int) {
	r := &app.assets.renderer
	scale := app.scale
	gap := BROWSE_GAP * scale
	heading_h = line_height(r, .Bold, BROWSE_TAB_SIZE * scale) + gap
	lines := line_height(r, .Bold, BROWSE_CARD_TITLE_SIZE * scale) + line_height(r, .Regular, BROWSE_CARD_TEXT_SIZE * scale)
	tile_h = max(OFFLINE_AVATAR * scale * r.text_scale, lines) + 16 * scale
	columns = max(1, int((width + gap) / (OFFLINE_TILE_WIDTH * scale * r.text_scale + gap)))
	return
}

// The offline channels from (x, y), `width` wide: a heading, then a tile each,
// added to Browse.cards after the live streams' cards.
draw_offline_section :: proc(app: ^App, x, y, width: f32, content: Rect) {
	o := &app.browse.offline
	if len(o.channels) == 0 {
		return
	}
	a := &app.assets
	r := &a.renderer
	b := &app.browse
	scale := app.scale
	gap := BROWSE_GAP * scale
	heading_h, tile_h, columns := offline_metrics(app, width)
	name_size := BROWSE_CARD_TITLE_SIZE * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	lh_name := line_height(r, .Bold, name_size)
	lh_text := line_height(r, .Regular, text_size)
	draw_text(r, .Bold, BROWSE_TAB_SIZE * scale, x, y, fmt.tprintf("Offline (%d)", len(o.channels)), BROWSE_DIM_TEXT)

	first := len(b.cards)
	tile_w := (width - gap * f32(columns - 1)) / f32(columns)
	now := time.now()
	for c, i in o.channels {
		tile := Rect{x + f32(i % columns) * (tile_w + gap), y + heading_h + f32(i / columns) * (tile_h + gap), tile_w, tile_h}
		append(&b.cards, tile)
		if tile.y > content.y + content.h || tile.y + tile.h < content.y {
			continue
		}
		draw_rect(r, tile, BROWSE_CARD_HOVER if first + i == b.hovered else BROWSE_PLACEHOLDER)
		pad := 8 * scale
		avatar := OFFLINE_AVATAR * scale * r.text_scale
		pic := Rect{tile.x + pad, tile.y + (tile.h - avatar) / 2, avatar, avatar}
		image := image_get(&a.images, &a.jobs, c.avatar_url, 1) if c.avatar_url != "" else nil
		if image != nil && image.state == .Ready {
			texture, _ := image_frame(image, a.now_ms)
			// Faded: they're offline.
			draw_image(r, texture, pic, {255, 255, 255, 150})
		} else {
			draw_rect(r, pic, BROWSE_CARD_HOVER)
		}
		tx := pic.x + pic.w + 10 * scale
		tw := tile.x + tile.w - pad - tx
		ty := tile.y + (tile.h - lh_name - lh_text) / 2
		name := c.display_name if c.display_name != "" else c.login
		draw_text(r, .Bold, name_size, tx, ty, fit_text(r, .Bold, name_size, name, tw), BROWSE_TEXT)
		detail := format_last_live(c.last_live, now)
		if c.last_game != "" && c.last_live != "" {
			detail = fmt.tprintf("%s · %s", detail, c.last_game)
		}
		draw_text(r, .Regular, text_size, tx, ty + lh_name, fit_text(r, .Regular, text_size, detail, tw), BROWSE_DIM_TEXT)
	}
}
