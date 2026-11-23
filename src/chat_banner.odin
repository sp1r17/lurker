package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// What's pinned and predicted on the channel being watched, shown above its
// chat: a pinned message, and a prediction with how the points are split.
// Twitch's chat doesn't carry them, so they're asked for every
// CHAT_BANNER_CHECK_MS while a live stream plays. Polls aren't: Twitch's
// GraphQL has no field for them that Lurker can find.

CHAT_BANNER_CHECK_MS :: 20_000

Chat_Banner :: struct {
	// The lines shown ("" for none). Owned.
	pinned:     string,
	prediction: string,
	next_at:    int,
	pending:    bool,
}

chat_banner_destroy :: proc(b: ^Chat_Banner) {
	delete(b.pinned)
	delete(b.prediction)
	b^ = {}
}

// The lines to show above the watched channel's chat, in order.
chat_banner_lines :: proc(b: ^Chat_Banner) -> (lines: [2]string, n: int) {
	for line in ([2]string{b.pinned, b.prediction}) {
		if line != "" {
			lines[n] = line
			n += 1
		}
	}
	return
}

// Asks what's pinned and predicted when it's time. Returns ms until it's next
// due, for the main loop's wait.
chat_banner_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	b := &w.banner
	if app.screen != .Watch || w.playing_vod || w.status != .Playing || w.channel == "" || b.pending {
		return -1
	}
	now := app.assets.now_ms
	if now < b.next_at {
		return b.next_at - now
	}
	b.pending = true
	b.next_at = now + CHAT_BANNER_CHECK_MS
	jobs_add(&app.assets.jobs, run_chat_banner_job, Chat_Banner_Job{client_id = strings.clone(app.client_id), login = strings.clone(w.channel), session = app.session})
	return CHAT_BANNER_CHECK_MS
}

Chat_Banner_Job :: struct {
	client_id, login: string,
	session:          int,
	ok:               bool,
	// The lines found. Owned.
	pinned:           string,
	prediction:       string,
}

destroy_chat_banner_job :: proc(p: ^Chat_Banner_Job) {
	delete(p.client_id)
	delete(p.login)
	delete(p.pinned)
	delete(p.prediction)
}

@(private = "file")
run_chat_banner_job :: proc(job: ^Job) {
	p := &job.payload.(Chat_Banner_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["login"] = p.login
	body, err := gql_post(
		p.client_id,
		"",
		"query($login: String!) { channel(name: $login) { pinnedChatMessages(first: 1) { edges { node { pinnedMessage { content { text } sender { displayName } } } } } activePredictionEvents { title status outcomes { title totalPoints } } } }",
		variables,
	)
	if err != .None {
		return
	}
	pinned, prediction, ok := parse_chat_banner_response(body)
	if !ok {
		return
	}
	p.ok = true
	p.pinned = strings.clone(pinned)
	p.prediction = strings.clone(prediction)
}

// The pinned message and the prediction as their lines ("" for none).
// Allocated with the temp allocator.
parse_chat_banner_response :: proc(body: []byte) -> (pinned, prediction: string, ok: bool) {
	r: struct {
		data: struct {
			channel: Maybe(struct {
				pinnedChatMessages:     Maybe(struct {
					edges: []struct {
						node: struct {
							pinnedMessage: Maybe(struct {
								content: struct {
									text: string,
								},
								sender:  Maybe(struct {
									displayName: string,
								}),
							}),
						},
					},
				}),
				activePredictionEvents: []struct {
					title:    string,
					status:   string,
					outcomes: []struct {
						title:       string,
						totalPoints: int,
					},
				},
			}),
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return "", "", false
	}
	channel, has_channel := r.data.channel.?
	if !has_channel {
		return "", "", true
	}
	if pins, has_pins := channel.pinnedChatMessages.?; has_pins && len(pins.edges) > 0 {
		if m, has_message := pins.edges[0].node.pinnedMessage.?; has_message && m.content.text != "" {
			sender := m.sender.? or_else {}
			pinned = fmt.tprintf("Pinned · %s: %s", sender.displayName, m.content.text) if sender.displayName != "" else fmt.tprintf("Pinned · %s", m.content.text)
		}
	}
	for e in channel.activePredictionEvents {
		// Resolved or canceled ones may linger in the list a moment.
		if e.status != "ACTIVE" && e.status != "LOCKED" {
			continue
		}
		total := 0
		for o in e.outcomes {
			total += o.totalPoints
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "Prediction%s · %s:", " (locked)" if e.status == "LOCKED" else "", e.title)
		for o, i in e.outcomes {
			share := 0 if total == 0 else int(f64(o.totalPoints) * 100 / f64(total) + 0.5)
			fmt.sbprintf(&b, "%s %s %d%%", " ·" if i > 0 else "", o.title, share)
		}
		prediction = strings.to_string(b)
		break
	}
	return pinned, prediction, true
}

finish_chat_banner_job :: proc(app: ^App, p: ^Chat_Banner_Job) {
	w := &app.watch
	if p.session != app.session || app.screen != .Watch || w.channel != p.login {
		return
	}
	w.banner.pending = false
	if !p.ok {
		return
	}
	delete(w.banner.pinned)
	delete(w.banner.prediction)
	w.banner.pinned, p.pinned = p.pinned, ""
	w.banner.prediction, p.prediction = p.prediction, ""
}
