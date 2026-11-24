package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:strings"

// Whispers, over Twitch's GraphQL with the sign-in Lurker has (site internals,
// not a documented API). While watching, the conversations with unread whispers
// are checked every WHISPERS_CHECK_MS, and each whisper not shown yet shows in
// the focused chat. "/w name message" in any chat box sends one.

WHISPERS_CHECK_MS :: 15_000
// The most whispers fetched from one conversation at a time.
WHISPERS_PER_THREAD :: 10

Whispers :: struct {
	// The whispers already shown, by ID (owned keys), so one stays unread on
	// Twitch without showing again.
	seen:    map[string]struct{},
	next_at: int,
	pending: bool,
}

whispers_destroy :: proc(w: ^Whispers) {
	for id in w.seen {
		delete(id)
	}
	delete(w.seen)
}

// Checks for whispers when it's time, while watching. Returns ms until it's next
// due, for the main loop's wait.
whispers_tick :: proc(app: ^App) -> (wait_ms: int) {
	ws := &app.whispers
	if app.screen != .Watch || !app.signed_in || ws.pending {
		return -1
	}
	now := app.assets.now_ms
	if now < ws.next_at {
		return ws.next_at - now
	}
	ws.pending = true
	ws.next_at = now + WHISPERS_CHECK_MS
	jobs_add(&app.assets.jobs, run_whispers_job, Whispers_Job{client_id = strings.clone(app.client_id), token = strings.clone(app.auth.access_token), self_id = strings.clone(app.auth.user_id)})
	return WHISPERS_CHECK_MS
}

// A whisper received: oldest first in a job's list. Owned.
Whisper :: struct {
	id, sent_at, name, text: string,
}

Whispers_Job :: struct {
	client_id, token, self_id: string,
	whispers:                  [dynamic]Whisper,
}

destroy_whispers_job :: proc(p: ^Whispers_Job) {
	delete(p.client_id)
	delete(p.token)
	delete(p.self_id)
	for w in p.whispers {
		delete(w.id)
		delete(w.sent_at)
		delete(w.name)
		delete(w.text)
	}
	delete(p.whispers)
}

@(private = "file")
run_whispers_job :: proc(job: ^Job) {
	p := &job.payload.(Whispers_Job)
	body, err := gql_post(p.client_id, p.token, "query { currentUser { whisperThreads(first: 20) { edges { node { id unreadMessagesCount } } } } }")
	if err != .None {
		return
	}
	threads: struct {
		data: struct {
			currentUser: Maybe(struct {
				whisperThreads: struct {
					edges: []struct {
						node: struct {
							id:                  string,
							unreadMessagesCount: int,
						},
					},
				},
			}),
		},
	}
	if json.unmarshal(body, &threads, allocator = context.temp_allocator) != nil {
		return
	}
	user := threads.data.currentUser.? or_else {}
	for e in user.whisperThreads.edges {
		if e.node.unreadMessagesCount <= 0 {
			continue
		}
		variables := make(map[string]string, context.temp_allocator)
		variables["id"] = e.node.id
		variables["n"] = fmt.tprint(min(e.node.unreadMessagesCount, WHISPERS_PER_THREAD))
		messages, message_err := gql_post(
			p.client_id,
			p.token,
			"query($id: ID!, $n: Int) { whisperThread(id: $id) { messages(first: $n) { edges { node { id sentAt from { id displayName } content { content } } } } } }",
			variables,
		)
		if message_err != .None {
			continue
		}
		for w in parse_whispers(messages, p.self_id) {
			append(&p.whispers, Whisper{strings.clone(w.id), strings.clone(w.sent_at), strings.clone(w.name), strings.clone(w.text)})
		}
	}
	slice.sort_by(p.whispers[:], proc(a, b: Whisper) -> bool {return a.sent_at < b.sent_at})
}

// The whispers in a conversation's messages, other than the user's own (sent
// by `self_id`). Allocated with the temp allocator.
parse_whispers :: proc(body: []byte, self_id: string) -> []Whisper {
	r: struct {
		data: struct {
			whisperThread: Maybe(struct {
				messages: struct {
					edges: []struct {
						node: struct {
							id:      string,
							sentAt:  string,
							from:    struct {
								id, displayName: string,
							},
							content: struct {
								content: string,
							},
						},
					},
				},
			}),
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil
	}
	thread := r.data.whisperThread.? or_else {}
	list := make([dynamic]Whisper, context.temp_allocator)
	for e in thread.messages.edges {
		n := e.node
		if n.id == "" || n.from.id == self_id || n.content.content == "" {
			continue
		}
		append(&list, Whisper{n.id, n.sentAt, n.from.displayName, n.content.content})
	}
	return list[:]
}

finish_whispers_job :: proc(app: ^App, p: ^Whispers_Job) {
	ws := &app.whispers
	ws.pending = false
	for w in p.whispers {
		if w.id in ws.seen {
			continue
		}
		ws.seen[strings.clone(w.id)] = {}
		if app.screen == .Watch {
			pane_notice(app, app.watch.panes[app.watch.focus], fmt.tprintf("Whisper from %s: %s", w.name, w.text))
		}
	}
}

// /w name message: sends a whisper, and says in `p` how it went.
whisper_send :: proc(app: ^App, p: ^Chat_Pane, login, text: string) {
	jobs_add(
		&app.assets.jobs,
		run_whisper_send_job,
		Whisper_Send_Job {
			client_id = strings.clone(app.client_id),
			token = strings.clone(app.auth.access_token),
			login = strings.clone(login),
			text = strings.clone(text),
			pane_id = p.id,
		},
	)
}

Whisper_Send_Job :: struct {
	client_id, token, login, text: string,
	pane_id:                       int,
	// What went wrong ("" when sent). Owned.
	failed:                        string,
}

destroy_whisper_send_job :: proc(p: ^Whisper_Send_Job) {
	delete(p.client_id)
	delete(p.token)
	delete(p.login)
	delete(p.text)
	delete(p.failed)
}

@(private = "file")
run_whisper_send_job :: proc(job: ^Job) {
	p := &job.payload.(Whisper_Send_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["login"] = p.login
	body, err := gql_post(p.client_id, p.token, "query($login: String!) { user(login: $login) { id } }", variables)
	user: struct {
		data: struct {
			user: Maybe(struct {
				id: string,
			}),
		},
	}
	if err != .None || json.unmarshal(body, &user, allocator = context.temp_allocator) != nil {
		p.failed = strings.clone("Twitch couldn't be reached")
		return
	}
	to, found := user.data.user.?
	if !found || to.id == "" {
		p.failed = strings.clone("there's no such user")
		return
	}
	send := make(map[string]string, context.temp_allocator)
	send["msg"] = p.text
	send["to"] = to.id
	// Twitch's guard against sending one whisper twice: new for each.
	send["nonce"] = fmt.tprintf("lurker-%x", rand.uint64())
	reply, send_err := gql_post(
		p.client_id,
		p.token,
		"mutation($msg: String!, $to: ID!, $nonce: String!) { sendWhisper(input: {message: $msg, nonce: $nonce, recipientUserID: $to}) { message { id } error { code } } }",
		send,
	)
	if send_err != .None {
		p.failed = strings.clone("Twitch refused it")
		return
	}
	p.failed = strings.clone(whisper_send_error(reply))
}

// Why Twitch didn't send a whisper, from sendWhisper's answer; "" if it did.
// Allocated with the temp allocator.
whisper_send_error :: proc(body: []byte) -> string {
	r: struct {
		data:   struct {
			sendWhisper: Maybe(struct {
				message: Maybe(struct {
					id: string,
				}),
				error:   Maybe(struct {
					code: string,
				}),
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return "Twitch's answer couldn't be read"
	}
	result := r.data.sendWhisper.? or_else {}
	if e, failed := result.error.?; failed && e.code != "" {
		return fmt.tprintf("Twitch said %s", e.code)
	}
	if m, sent := result.message.?; sent && m.id != "" {
		return ""
	}
	if len(r.errors) > 0 {
		log.warnf("whisper not sent: %s", r.errors[0].message)
		return fmt.tprintf("Twitch said \"%s\"", r.errors[0].message)
	}
	return "Twitch didn't say why"
}

finish_whisper_send_job :: proc(app: ^App, p: ^Whisper_Send_Job) {
	if app.screen != .Watch {
		return
	}
	for pane in app.watch.panes {
		if pane.id != p.pane_id {
			continue
		}
		if p.failed == "" {
			pane_notice(app, pane, fmt.tprintf("Whisper to %s: %s", p.login, p.text))
		} else {
			pane_notice(app, pane, fmt.tprintf("Couldn't whisper %s: %s.", p.login, p.failed))
		}
	}
}
