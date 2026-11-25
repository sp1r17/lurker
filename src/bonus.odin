package app

import "core:log"
import "core:strings"

// The channel points balance on the channel being watched, and claiming its
// bonus: Twitch offers one every 15 minutes or so of watching, which its own
// player learns of over PubSub. Lurker asks once a minute instead, while a live
// stream plays and someone is signed in, and claims it unless that's turned off
// (Layout.bonus_off).

BONUS_CHECK_MS :: 60_000

Bonus :: struct {
	// The balance, once known.
	balance: Maybe(int),
	// When to ask next (Assets.now_ms; 0: now), and whether an answer is due.
	next_at: int,
	pending: bool,
}

// Asks for the balance and any bonus when it's time. Returns ms until it's next
// due, for the main loop's wait.
bonus_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	b := &w.bonus
	if app.screen != .Watch || !app.signed_in || w.playing_vod || w.status != .Playing || w.channel == "" {
		return -1
	}
	now := app.assets.now_ms
	if b.pending {
		return -1
	}
	if now < b.next_at {
		return b.next_at - now
	}
	b.pending = true
	b.next_at = now + BONUS_CHECK_MS
	jobs_add(
		&app.assets.jobs,
		run_bonus_job,
		Bonus_Job {
			client_id = strings.clone(app.client_id),
			token = strings.clone(app.auth.access_token),
			login = strings.clone(w.channel),
			claim = !app.layout.bonus_off,
			session = app.session,
		},
	)
	return BONUS_CHECK_MS
}

Bonus_Job :: struct {
	client_id, token, login: string,
	claim:                   bool,
	session:                 int,
	// What came back: the balance, and the points a claim added.
	ok:                      bool,
	balance:                 int,
	claimed:                 int,
}

destroy_bonus_job :: proc(p: ^Bonus_Job) {
	delete(p.client_id)
	delete(p.token)
	delete(p.login)
}

@(private = "file")
run_bonus_job :: proc(job: ^Job) {
	p := &job.payload.(Bonus_Job)
	channel_id, balance, claim_id, err := get_channel_points(p.client_id, p.token, p.login)
	if err != .None {
		return
	}
	p.ok = true
	p.balance = balance
	if claim_id == "" || !p.claim {
		return
	}
	if after, claim_err := claim_channel_points(p.client_id, p.token, channel_id, claim_id); claim_err == .None {
		p.claimed = after - balance
		p.balance = after
	}
}

finish_bonus_job :: proc(app: ^App, p: ^Bonus_Job) {
	w := &app.watch
	if p.session != app.session || app.screen != .Watch || w.channel != p.login {
		return
	}
	w.bonus.pending = false
	if !p.ok {
		return
	}
	w.bonus.balance = p.balance
	if p.claimed > 0 {
		log.infof("claimed %d bonus channel points on %s", p.claimed, log_private(p.login))
	}
}
