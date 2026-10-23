package app

import "core:strings"

// "Following" stands out from both the stream info bar and a hovered search row.
FOLLOWING_BUTTON :: Color{0x3a, 0x3a, 0x44, 255}
FOLLOWING_BUTTON_HOVER :: Color{0x4a, 0x4a, 0x56, 255}

Follow_State :: enum {
	// Not looked up yet, or signed out: no button.
	Unknown,
	Not_Following,
	Following,
}

// Looks up whether the user follows the watched channel, or (with `set`)
// follows or unfollows it, or a channel in the search results (`from_search`).
Follow_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	login:     string,
	// Set by a lookup, given to a change. Owned.
	user_id:   string,
	set:       bool,
	from_search: bool,
	// What to change it to, or what a lookup found.
	following: bool,
	// The watch it's for; dropped if that's over.
	session:   int,
	check:     Auth_Check,
	ok:        bool,
}

destroy_follow_job :: proc(p: ^Follow_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.login)
	delete(p.user_id)
}

// Looks up whether the watched channel is followed, if signed in.
follow_lookup :: proc(app: ^App) {
	if !app.signed_in {
		return
	}
	follow_start(app, Follow_Job{login = strings.clone(app.watch.channel)})
}

@(private = "file")
follow_start :: proc(app: ^App, p: Follow_Job) {
	p := p
	p.client_id = strings.clone(app.client_id)
	p.auth = clone_auth(app.auth)
	p.session = app.session
	if !p.from_search {
		app.watch.follow_pending = true
	}
	jobs_add(&app.assets.jobs, run_follow_job, p)
}

@(private = "file")
run_follow_job :: proc(job: ^Job) {
	p := &job.payload.(Follow_Job)
	p.check = .Valid
	err := follow_request(p)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		err = follow_request(p)
	}
	p.ok = err == .None
}

@(private = "file")
follow_request :: proc(p: ^Follow_Job) -> Twitch_Error {
	if p.set {
		return set_follow(p.client_id, p.auth.access_token, p.user_id, p.following)
	}
	user_id, following, err := get_follow(p.client_id, p.auth.access_token, p.login)
	if err == .None {
		delete(p.user_id)
		p.user_id = strings.clone(user_id)
		p.following = following
	}
	return err
}

finish_follow_job :: proc(app: ^App, p: ^Follow_Job) {
	apply_auth_check(app, p.check, p.auth)
	if p.set && p.ok {
		// The browse screen's Following list is out of date now.
		app.browse.following.last_refresh = -BROWSE_REFRESH_MS
	}
	if p.from_search {
		// The results may have changed since; the channel may still be there.
		for &c in app.browse.results {
			if c.broadcaster_login == p.login {
				c.follow_pending = false
				if p.ok {
					c.follow = .Following if p.following else .Not_Following
				}
			}
		}
		return
	}
	w := &app.watch
	if app.screen != .Watch || p.session != app.session {
		return
	}
	w.follow_pending = false
	if !p.ok {
		// A failed change leaves the button as it was; a failed lookup, hidden.
		return
	}
	if !p.set {
		delete(w.channel_id)
		w.channel_id, p.user_id = p.user_id, ""
	}
	w.follow = .Following if p.following else .Not_Following
}

// A click on the watched channel's follow button.
follow_click :: proc(app: ^App) {
	w := &app.watch
	if follow_click_starts(w.follow, w.follow_pending, &w.unfollow_armed) {
		follow_start(
			app,
			Follow_Job {
				login = strings.clone(w.channel),
				user_id = strings.clone(w.channel_id),
				set = true,
				following = w.follow == .Not_Following,
			},
		)
	}
}

// A click on the follow button of search result `i` (an index into
// Browse.results).
follow_click_result :: proc(app: ^App, i: int) {
	b := &app.browse
	c := &b.results[i]
	armed := b.unfollow_armed == i + 1
	starts := follow_click_starts(c.follow, c.follow_pending, &armed)
	b.unfollow_armed = i + 1 if armed else 0
	if starts {
		c.follow_pending = true
		follow_start(
			app,
			Follow_Job {
				login = strings.clone(c.broadcaster_login),
				user_id = strings.clone(c.id),
				set = true,
				following = c.follow == .Not_Following,
				from_search = true,
			},
		)
	}
}

// Whether a click on a follow button should change the follow now: following is
// at once, but unfollowing takes a second click (which `armed` waits for),
// since it loses the follow's date.
@(private = "file")
follow_click_starts :: proc(state: Follow_State, pending: bool, armed: ^bool) -> bool {
	switch {
	case pending || state == .Unknown:
		return false
	case state == .Following && !armed^:
		armed^ = true
		return false
	}
	armed^ = false
	return true
}

// Draws the watched channel's follow button with its right edge at `right`,
// centred on `mid_y`. Returns its left edge, or `right` if there's no button.
draw_follow_button :: proc(app: ^App, right, mid_y: f32) -> f32 {
	w := &app.watch
	w.follow_button = draw_follow_pill(app, right, mid_y, w.follow, w.follow_pending, w.unfollow_armed)
	// Unfollowing waits for a second click only while the mouse stays on it.
	w.unfollow_armed &&= in_rect(w.follow_button, app.mouse.x, app.mouse.y)
	return w.follow_button.x if w.follow_button.w > 0 else right
}

// A follow button with its right edge at `right`, centred on `mid_y`: "Follow",
// "Following", or "Unfollow?" while `armed`. Returns where it is, or zero size if
// `state` is Unknown.
draw_follow_pill :: proc(app: ^App, right, mid_y: f32, state: Follow_State, pending, armed: bool) -> Rect {
	if state == .Unknown {
		return {}
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	labels := [3]string{"Follow", "Following", "Unfollow?"}
	// As wide as the widest label, so it doesn't jump when it changes.
	tw: f32
	for l in labels {
		tw = max(tw, text_width(r, .Bold, size, l))
	}
	bw := tw + 24 * scale
	bh := line_height(r, .Bold, size) + 12 * scale
	button := Rect{right - bw, mid_y - bh / 2, bw, bh}
	hovered := in_rect(button, app.mouse.x, app.mouse.y)
	label := labels[0]
	background := SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON
	switch {
	case armed:
		label, background = labels[2], LIVE_RED
	case state == .Following:
		label, background = labels[1], FOLLOWING_BUTTON_HOVER if hovered else FOLLOWING_BUTTON
	}
	draw_rect(r, button, background)
	draw_centered(r, .Bold, size, button, label, BROWSE_DIM_TEXT if pending else BROWSE_TEXT)
	return button
}
