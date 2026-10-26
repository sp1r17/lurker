package app

import "core:strings"

// How far ahead of the video the next batch of chat is fetched, in seconds.
REPLAY_FETCH_AHEAD :: 20
// How often the replay checks the video's position, while it plays.
REPLAY_TICK_MS :: 200
// A jump bigger than this, either way, is a seek: the chat starts again from there.
REPLAY_SEEK_JUMP :: 5

// A past broadcast's chat, replayed in the main chat as the video plays: messages
// are fetched in batches ahead of the video and shown when it reaches them.
Chat_Replay :: struct {
	active:     bool,
	// Fetched, not yet shown; in order. Owned.
	pending:    [dynamic]Replay_Message,
	// The cursor for the batch after `pending` ("" at the end), and whether one
	// is being fetched.
	next:       string,
	loading:    bool,
	// Bumped on every seek, so batches for an earlier position are dropped.
	generation: int,
	// The video's position at the last tick, in seconds.
	last_pos:   f64,
	failed:     bool,
	// The broadcast whose chat is replayed (owned), and how far into it the video
	// starts: a clip's broadcast and where the clip was cut from.
	video_id:   string,
	offset:     f64,
}

replay_destroy :: proc(r: ^Chat_Replay) {
	replay_clear_pending(r)
	delete(r.pending)
	delete(r.next)
	delete(r.video_id)
	r^ = {}
}

@(private = "file")
replay_clear_pending :: proc(r: ^Chat_Replay) {
	for m in r.pending {
		destroy_chat_message(m.message)
	}
	clear(&r.pending)
}

Vod_Chat_Job :: struct {
	client_id:  string,
	// A copy, empty when signed out; the job may refresh it.
	auth:       Auth,
	vod_id:     string,
	offset:     int,
	cursor:     string,
	session:    int,
	generation: int,
	check:      Auth_Check,
	ok:         bool,
	// Owned.
	messages:   [dynamic]Replay_Message,
	next:       string,
}

destroy_vod_chat_job :: proc(p: ^Vod_Chat_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.vod_id)
	delete(p.cursor)
	for m in p.messages {
		destroy_chat_message(m.message)
	}
	delete(p.messages)
	delete(p.next)
}

// Starts replaying the broadcast's chat from `start` seconds in, in place of the
// channel's live chat.
replay_start :: proc(app: ^App, start: f64) {
	w := &app.watch
	r := &w.replay
	r.active = true
	r.failed = false
	// A clip replays the chat of the broadcast it was cut from, from where it was.
	delete(r.video_id)
	r.video_id = strings.clone(w.vod.source_id if w.vod.kind == .Clip else w.vod.id)
	r.offset = f64(w.vod.source_offset) if w.vod.kind == .Clip else 0
	if r.video_id == "" {
		// That broadcast is gone: no chat, rather than live chat unrelated to it.
		r.failed = true
	}
	if len(w.panes) > 0 {
		// Nothing can be sent to it now.
		if typing, box, ok := focused_box(app); ok && typing == w.panes[0] && box == .Chat {
			box_unfocus(app)
		}
		pane_reply_cancel(w.panes[0])
	}
	replay_seek(app, start)
}

// Starts the chat again from `pos` seconds: clears what's shown and fetches the
// messages from there.
replay_seek :: proc(app: ^App, pos: f64) {
	w := &app.watch
	r := &w.replay
	if !r.active || len(w.panes) == 0 {
		return
	}
	r.generation += 1
	r.last_pos = pos
	replay_clear_pending(r)
	delete(r.next)
	r.next = ""
	p := w.panes[0]
	chat_view_clear(&p.view)
	if r.video_id == "" {
		replay_notice(app, "Chat isn't available for this clip.")
		return
	}
	if !r.failed {
		replay_notice(app, "Replaying the broadcast's chat")
	}
	replay_fetch(app, int(pos + r.offset), "")
}

@(private = "file")
replay_fetch :: proc(app: ^App, offset: int, cursor: string) {
	w := &app.watch
	r := &w.replay
	r.loading = true
	jobs_add(
		&app.assets.jobs,
		run_vod_chat_job,
		Vod_Chat_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth) if app.signed_in else {},
			vod_id = strings.clone(r.video_id),
			offset = offset,
			cursor = strings.clone(cursor),
			session = app.session,
			generation = r.generation,
		},
	)
}

@(private = "file")
run_vod_chat_job :: proc(job: ^Job) {
	p := &job.payload.(Vod_Chat_Job)
	p.check = .Valid
	messages, next, err := get_vod_comments(p.client_id, p.auth.access_token, p.vod_id, p.offset, p.cursor)
	if err == .Unauthorized && p.auth.refresh_token != "" {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		messages, next, err = get_vod_comments(p.client_id, p.auth.access_token, p.vod_id, p.offset, p.cursor)
	}
	if err != .None {
		return
	}
	p.ok = true
	p.messages = messages
	p.next = strings.clone(next)
}

finish_vod_chat_job :: proc(app: ^App, p: ^Vod_Chat_Job) {
	if p.auth.access_token != "" {
		apply_auth_check(app, p.check, p.auth)
	}
	w := &app.watch
	r := &w.replay
	if app.screen != .Watch || p.session != app.session || !r.active || p.generation != r.generation {
		return
	}
	r.loading = false
	if !p.ok {
		if !r.failed {
			r.failed = true
			replay_notice(app, "Chat replay isn't available for this clip." if w.vod.kind == .Clip else "Chat replay isn't available for this broadcast.")
		}
		return
	}
	append(&r.pending, ..p.messages[:])
	clear(&p.messages)
	delete(r.next)
	r.next, p.next = p.next, ""
	replay_tick(app)
}

// Shows the messages the video has reached, and fetches more ahead of it; notices
// seeks. Returns ms until it should run again, for the main loop's wait; -1 when
// not replaying.
replay_tick :: proc(app: ^App) -> int {
	w := &app.watch
	r := &w.replay
	if app.screen != .Watch || !r.active || w.status != .Playing || len(w.panes) == 0 {
		return -1
	}
	pos, ok := player_position(&app.player)
	if !ok {
		return REPLAY_TICK_MS
	}
	if pos < r.last_pos - REPLAY_SEEK_JUMP || pos > r.last_pos + REPLAY_SEEK_JUMP {
		replay_seek(app, pos)
		return REPLAY_TICK_MS
	}
	r.last_pos = pos

	// Where the video is in the broadcast whose chat this is.
	at := pos + r.offset
	shown := 0
	for shown < len(r.pending) && f64(r.pending[shown].offset) <= at {
		shown += 1
	}
	if shown > 0 {
		p := w.panes[0]
		batch := make([]Chat_Message, shown, context.temp_allocator)
		for &m, i in batch {
			m = r.pending[i].message
		}
		chat_view_add(&p.view, &app.assets, app.scale, p.messages_rect.w - 2 * CHAT_PADDING * app.scale, batch)
		remove_range(&r.pending, 0, shown)
	}

	ahead := f64(r.pending[len(r.pending) - 1].offset) if len(r.pending) > 0 else at
	if !r.loading && !r.failed && r.next != "" && ahead < at + REPLAY_FETCH_AHEAD {
		replay_fetch(app, 0, r.next)
	}
	return REPLAY_TICK_MS
}

@(private = "file")
replay_notice :: proc(app: ^App, text: string) {
	p := app.watch.panes[0]
	messages := []Chat_Message{system_message(text)}
	chat_view_add(&p.view, &app.assets, app.scale, p.messages_rect.w - 2 * CHAT_PADDING * app.scale, messages)
}
