package app

import "core:strings"

Follow_State :: enum {
	// Not looked up yet, or signed out: no button.
	Unknown,
	Not_Following,
	Following,
}

// Looks up whether the user follows the watched channel, or (with `set`)
// follows or unfollows it.
Follow_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	login:     string,
	// Set by a lookup, given to a change. Owned.
	user_id:   string,
	set:       bool,
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
	app.watch.follow_pending = true
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
	} else {
		// The browse screen's Following list is out of date now.
		app.browse.following.last_refresh = -BROWSE_REFRESH_MS
	}
	w.follow = .Following if p.following else .Not_Following
}

// A click on the follow button: follows at once, but unfollowing takes a second
// click, since it loses the follow's date.
follow_click :: proc(app: ^App) {
	w := &app.watch
	switch {
	case w.follow_pending || w.follow == .Unknown:
	case w.follow == .Following && !w.unfollow_armed:
		w.unfollow_armed = true
	case:
		w.unfollow_armed = false
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

// Draws the follow button with its right edge at `right`, centred on `mid_y`.
// Returns its left edge, or `right` if there's no button.
draw_follow_button :: proc(app: ^App, right, mid_y: f32) -> f32 {
	w := &app.watch
	w.follow_button = {}
	if w.follow == .Unknown {
		return right
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
	w.follow_button = {right - bw, mid_y - bh / 2, bw, bh}
	hovered := in_rect(w.follow_button, app.mouse.x, app.mouse.y)
	if !hovered {
		w.unfollow_armed = false
	}
	label := labels[0]
	background := SIGN_IN_BUTTON_HOVER if hovered else SIGN_IN_BUTTON
	switch {
	case w.unfollow_armed:
		label, background = labels[2], LIVE_RED
	case w.follow == .Following:
		label, background = labels[1], MENU_HOVER if hovered else BROWSE_CARD_HOVER
	}
	draw_rect(r, w.follow_button, background)
	draw_centered(r, .Bold, size, w.follow_button, label, BROWSE_DIM_TEXT if w.follow_pending else BROWSE_TEXT)
	return w.follow_button.x
}
