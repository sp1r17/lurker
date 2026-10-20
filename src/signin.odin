package app

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

SIGN_IN_CODE_SIZE :: 40
SIGN_IN_BUTTON :: Color{0x91, 0x47, 0xff, 255}
SIGN_IN_BUTTON_HOVER :: Color{0x77, 0x2c, 0xe8, 255}

Sign_In_State :: enum {
	Idle,
	// Asking Twitch for a code.
	Requesting,
	// Showing the code; polling until the user approves it.
	Waiting,
	Failed,
}

// Signing in from the browse screen with Twitch's device code flow, as
// SmartTwitchTV does: show a code, open twitch.tv/activate, poll until approved.
Sign_In :: struct {
	state:        Sign_In_State,
	code:         Device_Code,
	// In Assets.now_ms.
	expires_at:   int,
	next_poll:    int,
	interval_ms:  int,
	polling:      bool,
	// Bumped on cancel, so a job for an abandoned attempt is ignored.
	attempt:      int,
	// Set while drawing, in pixels.
	button:       Rect,
	link:         Rect,
	sign_out:     Rect,
}

sign_in_destroy :: proc(s: ^Sign_In) {
	destroy_device_code(s.code)
}

sign_in_start :: proc(app: ^App) {
	s := &app.sign_in
	if s.state == .Requesting || s.state == .Waiting {
		return
	}
	s.state = .Requesting
	s.attempt += 1
	jobs_add(
		&app.assets.jobs,
		run_device_start_job,
		Device_Start_Job{client_id = strings.clone(app.client_id), attempt = s.attempt},
	)
}

sign_in_cancel :: proc(app: ^App) {
	s := &app.sign_in
	destroy_device_code(s.code)
	s.code = {}
	s.state = .Idle
	s.attempt += 1
	s.polling = false
}

sign_in_active :: proc(app: ^App) -> bool {
	return app.sign_in.state == .Requesting || app.sign_in.state == .Waiting
}

// Forgets the sign-in, here and on disk.
sign_out :: proc(app: ^App) {
	if !app.signed_in {
		return
	}
	destroy_auth(app.auth)
	app.auth = {}
	app.signed_in = false
	delete_saved_auth()
	browse_clear(app)
}

// Polls when due. Returns ms until the next poll or countdown tick, for the main
// loop's wait.
sign_in_tick :: proc(app: ^App) -> (wait_ms: int) {
	s := &app.sign_in
	if s.state != .Waiting {
		return -1
	}
	now := app.assets.now_ms
	if now >= s.expires_at {
		sign_in_cancel(app)
		s.state = .Failed
		return -1
	}
	// The countdown on screen changes every second.
	countdown := 1000 - (s.expires_at - now) % 1000
	if s.polling {
		return countdown
	}
	if now < s.next_poll {
		return min(s.next_poll - now, countdown)
	}
	s.polling = true
	jobs_add(
		&app.assets.jobs,
		run_device_poll_job,
		Device_Poll_Job {
			client_id = strings.clone(app.client_id),
			device_code = strings.clone(s.code.device_code),
			attempt = s.attempt,
		},
	)
	return -1
}

Device_Start_Job :: struct {
	client_id: string,
	attempt:   int,
	ok:        bool,
	code:      Device_Code,
}

destroy_device_start_job :: proc(p: ^Device_Start_Job) {
	delete(p.client_id)
	destroy_device_code(p.code)
}

@(private = "file")
run_device_start_job :: proc(job: ^Job) {
	p := &job.payload.(Device_Start_Job)
	p.code, p.ok = device_code_start(p.client_id)
}

finish_device_start_job :: proc(app: ^App, p: ^Device_Start_Job) {
	s := &app.sign_in
	if p.attempt != s.attempt {
		return
	}
	if !p.ok {
		s.state = .Failed
		return
	}
	s.code, p.code = p.code, {}
	s.state = .Waiting
	now := app.assets.now_ms
	s.interval_ms = int(s.code.interval) * 1000
	s.next_poll = now + s.interval_ms
	s.expires_at = now + int(s.code.expires_in) * 1000
	// The link carries the code, so approving is one click in the browser. If no
	// browser opens, the code and link are on screen.
	_ = sdl.OpenURL(strings.clone_to_cstring(s.code.verification_uri, context.temp_allocator))
}

Device_Poll_Job :: struct {
	client_id:   string,
	device_code: string,
	attempt:     int,
	result:      Device_Poll,
	auth:        Auth,
}

destroy_device_poll_job :: proc(p: ^Device_Poll_Job) {
	delete(p.client_id)
	delete(p.device_code)
	destroy_auth(p.auth)
}

@(private = "file")
run_device_poll_job :: proc(job: ^Job) {
	p := &job.payload.(Device_Poll_Job)
	p.result, p.auth = device_code_poll(p.client_id, p.device_code)
}

finish_device_poll_job :: proc(app: ^App, p: ^Device_Poll_Job) {
	s := &app.sign_in
	if p.attempt != s.attempt {
		return
	}
	s.polling = false
	switch p.result {
	case .Pending:
		s.next_poll = app.assets.now_ms + s.interval_ms
	case .Slow_Down:
		s.interval_ms += 5000
		s.next_poll = app.assets.now_ms + s.interval_ms
	case .Failed:
		sign_in_cancel(app)
		s.state = .Failed
	case .Approved:
		sign_in_cancel(app)
		if app.signed_in {
			destroy_auth(app.auth)
		}
		app.auth, p.auth = p.auth, {}
		app.signed_in = true
		save_auth(app.auth)
		browse_refresh(app)
	}
}

// The signed-out browse screen: a button, or the code to enter.
draw_sign_in :: proc(app: ^App, area: Rect) {
	r := &app.assets.renderer
	s := &app.sign_in
	scale := app.scale
	size := BROWSE_CARD_TITLE_SIZE * scale
	lh := line_height(r, .Regular, size)
	s.button = {}
	s.link = {}

	switch s.state {
	case .Idle, .Failed:
		msg := "Sign in to see the channels you follow and to chat."
		if s.state == .Failed {
			msg = "Signing in didn't work, or the code expired. Try again?"
		}
		label := "Sign in with Twitch"
		bw := text_width(r, .Bold, size, label) + 40 * scale
		bh := lh + 20 * scale
		cy := area.y + area.h / 2
		draw_centered(r, .Regular, size, {area.x, cy - bh - lh, area.w, lh}, msg, BROWSE_DIM_TEXT)
		s.button = {area.x + (area.w - bw) / 2, cy, bw, bh}
		draw_rect(r, s.button, SIGN_IN_BUTTON_HOVER if in_rect(s.button, app.mouse.x, app.mouse.y) else SIGN_IN_BUTTON)
		draw_centered(r, .Bold, size, s.button, label, BROWSE_TEXT)
		draw_centered(r, .Regular, size * 0.85, {area.x, cy + bh + 8 * scale, area.w, lh}, "or press L", BROWSE_DIM_TEXT)
	case .Requesting:
		draw_centered(r, .Regular, size, area, "Getting a sign-in code...", BROWSE_DIM_TEXT)
	case .Waiting:
		code_size := SIGN_IN_CODE_SIZE * scale
		code_h := line_height(r, .Bold, code_size)
		top := area.y + (area.h - (lh * 3 + code_h + 24 * scale)) / 2
		draw_centered(r, .Regular, size, {area.x, top, area.w, lh}, "Your browser should have opened. If not, go to", BROWSE_DIM_TEXT)
		link_text := "twitch.tv/activate"
		lw := text_width(r, .Bold, size, link_text)
		s.link = {area.x + (area.w - lw) / 2, top + lh, lw, lh}
		draw_text(r, .Bold, size, s.link.x, s.link.y, link_text, BROWSE_ACCENT)
		draw_centered(r, .Bold, code_size, {area.x, top + 2 * lh + 12 * scale, area.w, code_h}, s.code.user_code, BROWSE_TEXT)
		remaining := max(0, (s.expires_at - app.assets.now_ms) / 1000)
		draw_centered(
			r,
			.Regular,
			size * 0.85,
			{area.x, top + 2 * lh + code_h + 24 * scale, area.w, lh},
			fmt.tprintf("Waiting for you to approve it (%d:%02d left) · Esc to cancel", remaining / 60, remaining % 60),
			BROWSE_DIM_TEXT,
		)
	}
}

// Handles a click on the sign-in screen or the header's "Sign out". Returns true
// if it was used.
sign_in_click :: proc(app: ^App, x, y: f32) -> bool {
	s := &app.sign_in
	switch {
	case s.button.w > 0 && in_rect(s.button, x, y):
		sign_in_start(app)
	case s.link.w > 0 && in_rect(s.link, x, y):
		_ = sdl.OpenURL(strings.clone_to_cstring(s.code.verification_uri, context.temp_allocator))
	case s.sign_out.w > 0 && in_rect(s.sign_out, x, y):
		sign_out(app)
	case:
		return false
	}
	return true
}
