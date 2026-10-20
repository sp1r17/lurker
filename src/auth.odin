package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Signing in uses Twitch's device code flow with SmartTwitchTV's client ID (see
// DEFAULT_CLIENT_ID): the app shows a code, the user enters it at
// twitch.tv/activate, and the app polls until they approve. No client secret is
// involved, so nothing secret ships in the binary.
DEVICE_URL :: "https://id.twitch.tv/oauth2/device"
VALIDATE_URL :: "https://id.twitch.tv/oauth2/validate"
AUTH_SCOPES :: "chat:read chat:edit user:read:follows user:read:subscriptions"
DEVICE_GRANT_TYPE :: "urn:ietf:params:oauth:grant-type:device_code"

// A signed-in user. Strings are owned; free with destroy_auth.
Auth :: struct {
	access_token:  string,
	refresh_token: string,
	// Unix seconds; 0 if Twitch gave no expiry. Informational: check_auth asks Twitch.
	expires_at:    i64,
	login:         string,
	user_id:       string,
}

destroy_auth :: proc(a: Auth) {
	delete(a.access_token)
	delete(a.refresh_token)
	delete(a.login)
	delete(a.user_id)
}

clone_auth :: proc(a: Auth) -> Auth {
	return {
		access_token = strings.clone(a.access_token),
		refresh_token = strings.clone(a.refresh_token),
		expires_at = a.expires_at,
		login = strings.clone(a.login),
		user_id = strings.clone(a.user_id),
	}
}

// ~/.config/twitch-app/auth.json, allocated with the temp allocator.
auth_path :: proc() -> (path: string, ok: bool) {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		return "", false
	}
	joined, join_err := filepath.join({dir, "twitch-app", "auth.json"}, context.temp_allocator)
	return joined, join_err == nil
}

load_auth :: proc() -> (a: Auth, ok: bool) {
	path := auth_path() or_return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	stored: Auth
	if json.unmarshal(data, &stored, allocator = context.temp_allocator) != nil || stored.access_token == "" {
		log.warnf("%s is unreadable; sign in again with --login", path)
		return {}, false
	}
	return clone_auth(stored), true
}

// The tokens are as good as a password, so only the user can read the file.
save_auth :: proc(a: Auth) -> bool {
	path, path_ok := auth_path()
	if !path_ok {
		return false
	}
	if err := os.make_directory_all(filepath.dir(path), {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		log.errorf("can't create the config folder: %v", err)
		return false
	}
	data, marshal_err := json.marshal(a, {pretty = true}, context.temp_allocator)
	if marshal_err != nil {
		return false
	}
	if err := os.write_entire_file(path, data, {.Read_User, .Write_User}); err != nil {
		log.errorf("can't save %s: %v", path, err)
		return false
	}
	return true
}

@(private = "file")
Token_Response :: struct {
	access_token:  string,
	refresh_token: string,
	expires_in:    i64,
	message:       string,
}

@(private = "file")
form :: proc(pairs: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i + 1 < len(pairs); i += 2 {
		if i > 0 {
			strings.write_byte(&sb, '&')
		}
		strings.write_string(&sb, pairs[i])
		strings.write_byte(&sb, '=')
		strings.write_string(&sb, net.percent_encode(pairs[i + 1], context.temp_allocator))
	}
	return strings.to_string(sb)
}

// Interactive sign-in for the terminal: prints the code and waits for approval.
// Blocks for up to the code's lifetime (about 30 minutes).
login_with_device_code :: proc(client_id: string) -> (a: Auth, ok: bool) {
	Device_Response :: struct {
		device_code:      string,
		user_code:        string,
		verification_uri: string,
		expires_in:       i64,
		interval:         i64,
	}
	res, req_ok := http_request(
		DEVICE_URL,
		post_body = form("client_id", client_id, "scopes", AUTH_SCOPES),
		allocator = context.temp_allocator,
	)
	if !req_ok {
		return {}, false
	}
	device: Device_Response
	if res.status != 200 || json.unmarshal(res.body, &device, allocator = context.temp_allocator) != nil {
		log.errorf(
			"Twitch refused the sign-in request (%d): %s",
			res.status,
			strings.trim_space(string(res.body)),
		)
		return {}, false
	}

	fmt.printfln("To sign in, open %s and enter the code %s", device.verification_uri, device.user_code)
	interval := max(device.interval, 5)
	deadline := time.time_to_unix(time.now()) + device.expires_in
	for time.time_to_unix(time.now()) < deadline {
		time.sleep(time.Duration(interval) * time.Second)
		poll, poll_ok := http_request(
			TOKEN_URL,
			post_body = form(
				"client_id",
				client_id,
				"scopes",
				AUTH_SCOPES,
				"device_code",
				device.device_code,
				"grant_type",
				DEVICE_GRANT_TYPE,
			),
			allocator = context.temp_allocator,
		)
		if !poll_ok {
			continue
		}
		token: Token_Response
		_ = json.unmarshal(poll.body, &token, allocator = context.temp_allocator)
		switch {
		case poll.status == 200 && token.access_token != "":
			return finish_login(client_id, token)
		case token.message == "authorization_pending":
		case token.message == "slow_down":
			interval += 5
		case:
			log.errorf("sign-in failed (%d): %s", poll.status, strings.trim_space(string(poll.body)))
			return {}, false
		}
	}
	log.error("the sign-in code expired")
	return {}, false
}

// Looks up who the token belongs to.
@(private = "file")
finish_login :: proc(client_id: string, token: Token_Response) -> (a: Auth, ok: bool) {
	Users_Response :: struct {
		data: []struct {
			id:    string,
			login: string,
		},
	}
	body, err := helix_get(client_id, token.access_token, "/users")
	users: Users_Response
	if err != .None || json.unmarshal(body, &users, allocator = context.temp_allocator) != nil || len(users.data) == 0 {
		log.error("signed in, but can't look up the account")
		return {}, false
	}
	return clone_auth(
		{
			access_token = token.access_token,
			refresh_token = token.refresh_token,
			expires_at = time.time_to_unix(time.now()) + token.expires_in if token.expires_in > 0 else 0,
			login = users.data[0].login,
			user_id = users.data[0].id,
		},
	), true
}

Auth_Check :: enum {
	// Still valid; nothing changed.
	Valid,
	// Refreshed: the new tokens are in the Auth and should be saved.
	Refreshed,
	// Rejected and can't be refreshed: the user must sign in again.
	Signed_Out,
	// Twitch couldn't be reached; the tokens may still be good.
	Unreachable,
}

// Validates the token at startup (Twitch asks apps to), refreshing it only if
// Twitch rejects it. The expiry isn't trusted: Twitch reports none for some client
// IDs, whose tokens last until revoked. Blocks: call from a worker thread.
check_auth :: proc(client_id: string, a: ^Auth) -> Auth_Check {
	res, ok := http_request(
		VALIDATE_URL,
		{strings.concatenate({"Authorization: OAuth ", a.access_token}, context.temp_allocator)},
		allocator = context.temp_allocator,
	)
	if !ok {
		return .Unreachable
	}
	switch res.status {
	case 200:
		return .Valid
	case 401:
		return refresh_auth(client_id, a)
	case:
		log.warnf("validating the sign-in returned %d", res.status)
		return .Unreachable
	}
}

refresh_auth :: proc(client_id: string, a: ^Auth) -> Auth_Check {
	if a.refresh_token == "" {
		return .Signed_Out
	}
	res, ok := http_request(
		TOKEN_URL,
		post_body = form("client_id", client_id, "grant_type", "refresh_token", "refresh_token", a.refresh_token),
		allocator = context.temp_allocator,
	)
	if !ok {
		return .Unreachable
	}
	token: Token_Response
	if res.status != 200 || json.unmarshal(res.body, &token, allocator = context.temp_allocator) != nil || token.access_token == "" {
		log.warnf("Twitch rejected the saved sign-in (%d); sign in again with --login", res.status)
		return .Signed_Out
	}
	delete(a.access_token)
	delete(a.refresh_token)
	a.access_token = strings.clone(token.access_token)
	a.refresh_token = strings.clone(token.refresh_token)
	a.expires_at = time.time_to_unix(time.now()) + token.expires_in if token.expires_in > 0 else 0
	return .Refreshed
}
