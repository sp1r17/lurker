package app

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Moderating through Twitch's API, in channels the user moderates. Each action
// needs a permission that sign-ins from before Lurker asked for it don't have.
MOD_SCOPE_BANS :: "moderator:manage:banned_users"
MOD_SCOPE_CHAT :: "moderator:manage:chat_messages"
// Twitch's longest timeout: two weeks.
MAX_TIMEOUT_SECONDS :: 1_209_600
DEFAULT_TIMEOUT_SECONDS :: 600

Mod_Action :: enum {
	Ban,
	Timeout,
	Unban,
	Delete,
	Clear,
}

Mod_Result :: enum {
	Failed,
	Done,
	// The sign-in lacks the permission: the user must sign in again.
	Needs_Sign_In,
}

Mod_Job :: struct {
	client_id:  string,
	// A copy; the job may refresh it.
	auth:       Auth,
	pane:       int,
	action:     Mod_Action,
	channel_id: string,
	// Whom it's for (Ban, Timeout, Unban): their ID, looked up from the login if "".
	login:      string,
	user_id:    string,
	// The message to delete.
	message_id: string,
	reason:     string,
	seconds:    int,
	check:      Auth_Check,
	result:     Mod_Result,
	// Why it failed, in Twitch's words when it gave some.
	error:      string,
}

destroy_mod_job :: proc(p: ^Mod_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.channel_id)
	delete(p.login)
	delete(p.user_id)
	delete(p.message_id)
	delete(p.reason)
	delete(p.error)
}

// Whether the user moderates `p`'s chat, or it's their own channel.
pane_moderating :: proc(p: ^Chat_Pane) -> bool {
	if p.chat == nil {
		return false
	}
	_, self := chat_room(p.chat)
	return self.moderator || self.broadcaster
}

// Moderates `p`'s chat: bans, times out or unbans `login` (or `user_id`, when
// known), deletes message `message_id`, or clears the chat.
mod_request :: proc(app: ^App, p: ^Chat_Pane, action: Mod_Action, login := "", user_id := "", message_id := "", seconds := 0, reason := "") {
	if !app.signed_in || !pane_moderating(p) {
		pane_notice(app, p, "You're not a moderator in this chat.")
		return
	}
	if p.room_id == "" {
		pane_notice(app, p, "Still joining the chat; try again in a moment.")
		return
	}
	jobs_add(
		&app.assets.jobs,
		run_mod_job,
		Mod_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth),
			pane = p.id,
			action = action,
			channel_id = strings.clone(p.room_id),
			login = strings.clone(login),
			user_id = strings.clone(user_id),
			message_id = strings.clone(message_id),
			reason = strings.clone(reason),
			seconds = seconds,
		},
	)
}

@(private = "file")
run_mod_job :: proc(job: ^Job) {
	p := &job.payload.(Mod_Job)
	p.check = .Valid
	scopes, err := token_scopes(p.auth.access_token)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		scopes, err = token_scopes(p.auth.access_token)
	}
	if err != .None {
		p.error = strings.clone("Twitch couldn't be reached")
		return
	}
	needed := MOD_SCOPE_CHAT if p.action == .Delete || p.action == .Clear else MOD_SCOPE_BANS
	if !slice.contains(scopes, needed) {
		p.result = .Needs_Sign_In
		return
	}
	if p.user_id == "" && (p.action == .Ban || p.action == .Timeout || p.action == .Unban) {
		body, lookup_err := helix_get(p.client_id, p.auth.access_token, fmt.tprintf("/users?login=%s", p.login))
		user: User_Info
		found := false
		if lookup_err == .None {
			user, found = parse_user(body)
		}
		if !found {
			p.error = strings.clone("no such user")
			return
		}
		p.user_id, user.id = user.id, ""
		destroy_user_info(user)
	}

	query := fmt.tprintf("broadcaster_id=%s&moderator_id=%s", p.channel_id, p.auth.user_id)
	method, path, body: string
	switch p.action {
	case .Ban, .Timeout:
		Ban :: struct {
			user_id: string,
			reason:  string,
		}
		Timeout :: struct {
			user_id:  string,
			duration: int,
			reason:   string,
		}
		data: []byte
		if p.action == .Ban {
			data, _ = json.marshal(struct {
					data: Ban,
				}{{p.user_id, p.reason}}, allocator = context.temp_allocator)
		} else {
			data, _ = json.marshal(struct {
					data: Timeout,
				}{{p.user_id, p.seconds, p.reason}}, allocator = context.temp_allocator)
		}
		method, path, body = "POST", fmt.tprintf("/moderation/bans?%s", query), string(data)
	case .Unban:
		method, path = "DELETE", fmt.tprintf("/moderation/bans?%s&user_id=%s", query, p.user_id)
	case .Delete:
		method, path = "DELETE", fmt.tprintf("/moderation/chat?%s&message_id=%s", query, p.message_id)
	case .Clear:
		method, path = "DELETE", fmt.tprintf("/moderation/chat?%s", query)
	}
	headers := []string {
		strings.concatenate({"Client-Id: ", p.client_id}, context.temp_allocator),
		strings.concatenate({"Authorization: Bearer ", p.auth.access_token}, context.temp_allocator),
		"Content-Type: application/json",
	}
	res, ok := http_request(strings.concatenate({HELIX_URL, path}, context.temp_allocator), headers, post_body = body, allocator = context.temp_allocator, method = method)
	switch {
	case !ok:
		p.error = strings.clone("Twitch couldn't be reached")
	case res.status == 200 || res.status == 204:
		p.result = .Done
	case:
		p.error = strings.clone(helix_error_message(res.body, res.status))
	}
}

// The scopes the token was granted, from Twitch's validation endpoint. Allocated
// with the temp allocator.
@(private = "file")
token_scopes :: proc(token: string) -> (scopes: []string, err: Twitch_Error) {
	res, ok := http_request(
		VALIDATE_URL,
		{strings.concatenate({"Authorization: OAuth ", token}, context.temp_allocator)},
		allocator = context.temp_allocator,
	)
	if !ok {
		return nil, .Request_Failed
	}
	if res.status == 401 {
		return nil, .Unauthorized
	}
	if res.status != 200 {
		return nil, .Bad_Status
	}
	Validation :: struct {
		scopes: []string,
	}
	v: Validation
	if json.unmarshal(res.body, &v, allocator = context.temp_allocator) != nil {
		return nil, .Bad_Json
	}
	return v.scopes, .None
}

// Twitch's reason for refusing a request ("The user specified in the user_id field
// is already banned."), or the status. Allocated with the temp allocator.
helix_error_message :: proc(body: []byte, status: int) -> string {
	Error :: struct {
		message: string,
	}
	e: Error
	if json.unmarshal(body, &e, allocator = context.temp_allocator) == nil && e.message != "" {
		return e.message
	}
	return fmt.tprintf("Twitch said %d", status)
}

finish_mod_job :: proc(app: ^App, p: ^Mod_Job) {
	apply_auth_check(app, p.check, p.auth)
	pane := find_pane(app, p.pane)
	if pane == nil || app.screen != .Watch {
		return
	}
	// Bans, timeouts, deletions and clears come back through the chat itself.
	switch p.result {
	case .Done:
		if p.action == .Unban {
			pane_notice(app, pane, fmt.tprintf("%s can chat again.", p.login if p.login != "" else "They"))
		}
	case .Needs_Sign_In:
		pane_notice(app, pane, "Sign out and in again to moderate from Lurker: your sign-in is from before it asked Twitch for that.")
	case .Failed:
		if p.check == .Signed_Out {
			return
		}
		verb: string
		switch p.action {
		case .Ban:
			verb = "ban"
		case .Timeout:
			verb = "time out"
		case .Unban:
			verb = "unban"
		case .Delete:
			verb = "delete the message"
		case .Clear:
			verb = "clear the chat"
		}
		who := fmt.tprintf(" %s", p.login) if p.login != "" && p.action != .Delete else ""
		pane_notice(app, pane, fmt.tprintf("Couldn't %s%s: %s", verb, who, p.error))
	}
}

// Seconds from "600", "30s", "10m", "1h", "1d" or "2w". False for anything else.
parse_timeout :: proc(s: string) -> (seconds: int, ok: bool) {
	if s == "" {
		return 0, false
	}
	unit := 1
	digits := s
	switch s[len(s) - 1] {
	case 's':
		digits = s[:len(s) - 1]
	case 'm':
		unit, digits = 60, s[:len(s) - 1]
	case 'h':
		unit, digits = 3600, s[:len(s) - 1]
	case 'd':
		unit, digits = 86400, s[:len(s) - 1]
	case 'w':
		unit, digits = 7 * 86400, s[:len(s) - 1]
	}
	n, parsed := strconv.parse_int(digits, 10)
	if !parsed || n <= 0 || n > MAX_TIMEOUT_SECONDS / unit {
		return 0, false
	}
	return n * unit, true
}
