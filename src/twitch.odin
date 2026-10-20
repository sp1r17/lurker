package app

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

TOKEN_URL :: "https://id.twitch.tv/oauth2/token"
STREAMS_URL :: "https://api.twitch.tv/helix/streams"
// Helix accepts at most 100 user_login parameters per request.
MAX_LOGINS_PER_REQUEST :: 100

Stream :: struct {
	user_login:   string,
	user_name:    string,
	game_name:    string,
	title:        string,
	viewer_count: int,
	started_at:   string,
}

Twitch_Error :: enum {
	None,
	Curl_Failed,
	Unauthorized,
	Bad_Status,
	Bad_Json,
}

Http_Response :: struct {
	status: int,
	body:   []byte,
}

// Runs curl with its options fed through stdin (curl's --config -), so the client
// secret and access token never show up in the process list. The body is allocated
// with the temp allocator.
@(private = "file")
curl :: proc(options: string) -> (res: Http_Response, err: Twitch_Error) {
	stdin_r, stdin_w, pipe_err := os.pipe()
	if pipe_err != nil {
		return {}, .Curl_Failed
	}
	defer os.close(stdin_r)
	// curl's options are a few hundred bytes, well under the pipe's buffer, so writing
	// them all before curl starts can't block.
	_, write_err := os.write_string(stdin_w, options)
	os.close(stdin_w)
	if write_err != nil {
		return {}, .Curl_Failed
	}

	// -w puts the status code on its own line after the body.
	state, stdout, stderr, exec_err := os.process_exec(
		{command = {"curl", "-sS", "--max-time", "15", "-w", "\n%{http_code}", "--config", "-"}, stdin = stdin_r},
		context.temp_allocator,
	)
	if exec_err != nil || !state.success {
		log.warnf("curl failed: %s", strings.trim_space(string(stderr)))
		return {}, .Curl_Failed
	}
	return split_status(stdout)
}

split_status :: proc(out: []byte) -> (res: Http_Response, err: Twitch_Error) {
	text := string(out)
	newline := strings.last_index_byte(text, '\n')
	if newline < 0 {
		return {}, .Curl_Failed
	}
	status, ok := strconv.parse_int(text[newline + 1:])
	if !ok {
		return {}, .Curl_Failed
	}
	return {status = status, body = out[:newline]}, .None
}

// Quotes a value for a curl config file.
@(private = "file")
quote :: proc(sb: ^strings.Builder, value: string) {
	strings.write_byte(sb, '"')
	for c in transmute([]byte)value {
		if c == '"' || c == '\\' {
			strings.write_byte(sb, '\\')
		}
		strings.write_byte(sb, c)
	}
	strings.write_byte(sb, '"')
}

// Gets an app access token with the client credentials flow. The token is allocated
// with the context allocator.
get_app_token :: proc(creds: Credentials) -> (token: string, err: Twitch_Error) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "url = ")
	quote(&sb, TOKEN_URL)
	strings.write_string(&sb, "\ndata = ")
	quote(
		&sb,
		strings.concatenate(
			{"client_id=", creds.client_id, "&client_secret=", creds.client_secret, "&grant_type=client_credentials"},
			context.temp_allocator,
		),
	)
	strings.write_byte(&sb, '\n')

	res := curl(strings.to_string(sb)) or_return
	if res.status != 200 {
		log.warnf("token request returned %d: %s", res.status, strings.trim_space(string(res.body)))
		return "", .Bad_Status
	}
	return parse_token_response(res.body)
}

parse_token_response :: proc(body: []byte) -> (token: string, err: Twitch_Error) {
	Token_Response :: struct {
		access_token: string,
	}
	r: Token_Response
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil || r.access_token == "" {
		return "", .Bad_Json
	}
	return strings.clone(r.access_token), .None
}

// Returns the channels in `logins` that are live. Everything is allocated with the
// temp allocator.
get_live_streams :: proc(creds: Credentials, token: string, logins: []string) -> (streams: []Stream, err: Twitch_Error) {
	all := make([dynamic]Stream, context.temp_allocator)
	for start := 0; start < len(logins); start += MAX_LOGINS_PER_REQUEST {
		batch := logins[start:min(start + MAX_LOGINS_PER_REQUEST, len(logins))]

		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "url = ")
		quote(&sb, streams_url(batch))
		strings.write_string(&sb, "\nheader = ")
		quote(&sb, strings.concatenate({"Client-Id: ", creds.client_id}, context.temp_allocator))
		strings.write_string(&sb, "\nheader = ")
		quote(&sb, strings.concatenate({"Authorization: Bearer ", token}, context.temp_allocator))
		strings.write_byte(&sb, '\n')

		res := curl(strings.to_string(sb)) or_return
		switch res.status {
		case 200:
		case 401:
			return nil, .Unauthorized
		case:
			log.warnf("streams request returned %d: %s", res.status, strings.trim_space(string(res.body)))
			return nil, .Bad_Status
		}
		append(&all, ..parse_streams_response(res.body) or_return)
	}
	return all[:], .None
}

streams_url :: proc(logins: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, STREAMS_URL)
	strings.write_string(&sb, "?first=100")
	for login in logins {
		strings.write_string(&sb, "&user_login=")
		strings.write_string(&sb, login)
	}
	return strings.to_string(sb)
}

parse_streams_response :: proc(body: []byte) -> (streams: []Stream, err: Twitch_Error) {
	Streams_Response :: struct {
		data: []Stream,
	}
	r: Streams_Response
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, .Bad_Json
	}
	return r.data, .None
}
