package app

import "core:fmt"
import "core:log"
import "core:strings"

// Claiming finished drops: while a live stream plays and someone is signed in,
// their drops inventory is checked every DROPS_CHECK_MS, and each drop finished
// but not claimed is claimed, unless that's turned off (Layout.drops_off). The
// chat says which. Twitch's site internals, not a documented API.

DROPS_CHECK_MS :: 5 * 60_000

Drops :: struct {
	// When to check next (Assets.now_ms; 0: now), and whether an answer is due.
	next_at: int,
	pending: bool,
}

// Checks for finished drops when it's time. Returns ms until it's next due, for
// the main loop's wait.
drops_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	d := &w.drops
	if app.screen != .Watch || !app.signed_in || app.layout.drops_off || w.playing_vod || w.status != .Playing || d.pending {
		return -1
	}
	now := app.assets.now_ms
	if now < d.next_at {
		return d.next_at - now
	}
	d.pending = true
	d.next_at = now + DROPS_CHECK_MS
	jobs_add(&app.assets.jobs, run_drops_job, Drops_Job{client_id = strings.clone(app.client_id), token = strings.clone(app.auth.access_token), session = app.session})
	return DROPS_CHECK_MS
}

Drops_Job :: struct {
	client_id, token: string,
	session:          int,
	// The drops claimed, as "Name (Game)". Owned.
	claimed:          [dynamic]string,
}

destroy_drops_job :: proc(p: ^Drops_Job) {
	delete(p.client_id)
	delete(p.token)
	for c in p.claimed {
		delete(c)
	}
	delete(p.claimed)
}

@(private = "file")
run_drops_job :: proc(job: ^Job) {
	p := &job.payload.(Drops_Job)
	drops, err := get_finished_drops(p.client_id, p.token)
	if err != .None {
		return
	}
	for d in drops {
		if claim_drop(p.client_id, p.token, d.instance_id) == .None {
			append(&p.claimed, fmt.aprintf("%s (%s)", d.name, d.game) if d.game != "" else strings.clone(d.name))
		}
	}
}

finish_drops_job :: proc(app: ^App, p: ^Drops_Job) {
	w := &app.watch
	if p.session != app.session || app.screen != .Watch {
		return
	}
	w.drops.pending = false
	for name in p.claimed {
		log.infof("claimed the drop %s", log_private(name))
		pane_notice(app, w.panes[0], fmt.tprintf("Claimed the drop %s.", name))
	}
}
