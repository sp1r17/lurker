package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

// The service Chatterino uses for what was said in a channel before joining:
// Twitch's IRC only sends what's said after.
RECENT_MESSAGES_URL :: "https://recent-messages.robotty.de/api/v2/recent-messages/%s?limit=%d"
RECENT_MESSAGES_LIMIT :: 100

History_Job :: struct {
	pane:     int,
	channel:  string,
	messages: [dynamic]Chat_Message,
}

destroy_history_job :: proc(p: ^History_Job) {
	delete(p.channel)
	for m in p.messages {
		destroy_chat_message(m)
	}
	delete(p.messages)
}

// Fetches what was said in the pane's channel before it joined.
history_request :: proc(app: ^App, p: ^Chat_Pane) {
	jobs_add(&app.assets.jobs, run_history_job, History_Job{pane = p.id, channel = strings.clone(p.channel)})
}

@(private = "file")
run_history_job :: proc(job: ^Job) {
	p := &job.payload.(History_Job)
	res, ok := http_request(fmt.tprintf(RECENT_MESSAGES_URL, p.channel, RECENT_MESSAGES_LIMIT), allocator = context.temp_allocator)
	if !ok {
		return
	}
	if res.status != 200 {
		log.warnf("recent messages: HTTP %d", res.status)
		return
	}
	if !parse_history(res.body, &p.messages) {
		log.warn("recent messages: unexpected response")
	}
}

// The chat messages in a recent-messages response (IRC lines), oldest first.
parse_history :: proc(body: []byte, out: ^[dynamic]Chat_Message) -> bool {
	Response :: struct {
		messages: []string,
	}
	r: Response
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return false
	}
	for line in r.messages {
		if msg, ok := parse_irc(line); ok {
			irc_chat_messages(msg, out, history = true)
		}
	}
	return true
}

finish_history_job :: proc(app: ^App, p: ^History_Job) {
	pane := find_pane(app, p.pane)
	if pane == nil || pane.channel != p.channel || pane_replaying(app, pane) {
		return
	}
	chat_view_prepend(&pane.view, &app.assets, app.scale, pane_text_width(app, pane), p.messages[:], app.auth.login if app.signed_in else "")
	// The view owns them now.
	clear(&p.messages)
}
