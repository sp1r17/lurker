package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"

// Voting in the watched channel's poll by clicking a choice's bar in the chat
// banner (chat_banner.odin). Only signed in, only while the poll is open, and
// only the free vote: votes bought with Bits or channel points aren't offered.

// Sending a vote, or why the last one didn't go through.
Poll_Vote :: struct {
	sending: bool,
	// "" if it went through. Owned.
	error:   string,
}

// Whether choice `i` of the poll shown can be voted for: signed in, the poll
// open, and not voted in yet (or, when it takes more than one choice, not for
// this one).
poll_votable :: proc(app: ^App, i: int) -> bool {
	b := &app.watch.banner
	poll := &b.poll
	if !app.signed_in || app.auth.user_id == "" || b.vote.sending || poll.ended || poll.id == "" || i < 0 || i >= len(poll.choices) || poll.choices[i].id == "" {
		return false
	}
	if b.poll_ends_at <= app.assets.now_ms {
		return false
	}
	for c, j in poll.choices {
		if c.mine && (j == i || !poll.multichoice) {
			return false
		}
	}
	return true
}

// What the poll's status says while voting, or after it failed ("" otherwise).
// Allocated with the temp allocator.
poll_vote_status :: proc(v: ^Poll_Vote) -> string {
	switch {
	case v.sending:
		return "Voting…"
	case v.error != "":
		return fmt.tprintf("Couldn't vote: %s", bet_error_text(v.error))
	}
	return ""
}

Poll_Vote_Job :: struct {
	client_id, token, login: string,
	user_id:                 string,
	poll_id, choice_id:      string,
	choice:                  int,
	session:                 int,
	// Why it didn't go through ("" if it did). Owned.
	error:                   string,
}

destroy_poll_vote_job :: proc(p: ^Poll_Vote_Job) {
	delete(p.client_id)
	delete(p.token)
	delete(p.login)
	delete(p.user_id)
	delete(p.poll_id)
	delete(p.choice_id)
	delete(p.error)
}

// Votes for choice `i` (an index) of the poll shown.
poll_vote_start :: proc(app: ^App, i: int) {
	w := &app.watch
	b := &w.banner
	if !poll_votable(app, i) {
		return
	}
	delete(b.vote.error)
	b.vote.error = ""
	b.vote.sending = true
	jobs_add(
		&app.assets.jobs,
		run_poll_vote_job,
		Poll_Vote_Job {
			client_id = strings.clone(app.client_id),
			token = strings.clone(app.auth.access_token),
			login = strings.clone(w.channel),
			user_id = strings.clone(app.auth.user_id),
			poll_id = strings.clone(b.poll.id),
			choice_id = strings.clone(b.poll.choices[i].id),
			choice = i,
			session = app.session,
		},
	)
}

@(private = "file")
run_poll_vote_job :: proc(job: ^Job) {
	p := &job.payload.(Poll_Vote_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["poll"] = p.poll_id
	variables["choice"] = p.choice_id
	variables["user"] = p.user_id
	// New for each vote, so Twitch counts one sent twice once.
	variables["vote"] = fmt.tprintf("%016x%016x", rand.uint64(), rand.uint64())
	code := "REQUEST_FAILED"
	body, err := gql_post(
		p.client_id,
		p.token,
		"mutation($poll: ID!, $choice: ID!, $user: ID!, $vote: ID!) { voteInPoll(input: {pollID: $poll, choiceID: $choice, userID: $user, voteID: $vote}) { error { code } } }",
		variables,
	)
	if err == .None {
		code = parse_vote_in_poll_response(body)
	}
	if code != "" {
		log.warnf("voting in a poll failed: %s", code)
		p.error = strings.clone(code)
	}
}

// Why Twitch refused the vote, or "" if it took it.
parse_vote_in_poll_response :: proc(body: []byte) -> string {
	r: struct {
		data:   struct {
			voteInPoll: Maybe(struct {
				error: Maybe(struct {
					code: string,
				}),
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return "BAD_RESPONSE"
	}
	if len(r.errors) > 0 {
		graphql_error(r.errors[0].message)
		return "REQUEST_FAILED"
	}
	result, ok := r.data.voteInPoll.?
	if !ok {
		return "BAD_RESPONSE"
	}
	if e, failed := result.error.?; failed {
		return e.code if e.code != "" else "REFUSED"
	}
	return ""
}

finish_poll_vote_job :: proc(app: ^App, p: ^Poll_Vote_Job) {
	w := &app.watch
	b := &w.banner
	if p.session != app.session || w.channel != p.login {
		return
	}
	b.vote.sending = false
	if p.error != "" {
		delete(b.vote.error)
		b.vote.error, p.error = p.error, ""
		return
	}
	// Shown as theirs straight away; asking again soon confirms it.
	if b.poll.id == p.poll_id && p.choice < len(b.poll.choices) {
		c := &b.poll.choices[p.choice]
		c.mine = true
		c.votes += 1
	}
	b.next_at = 0
}
