package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

TOKEN_URL :: "https://id.twitch.tv/oauth2/token"
HELIX_URL :: "https://api.twitch.tv/helix"
// Helix accepts at most 100 user_login parameters per request.
MAX_LOGINS_PER_REQUEST :: 100

// A live stream, as Helix describes it.
Stream :: struct {
	user_id:       string,
	user_login:    string,
	user_name:     string,
	game_name:     string,
	title:         string,
	viewer_count:  int,
	started_at:    string,
	// With "{width}" and "{height}" placeholders.
	thumbnail_url: string,
}

clone_stream :: proc(s: Stream) -> Stream {
	return {
		user_id = strings.clone(s.user_id),
		user_login = strings.clone(s.user_login),
		user_name = strings.clone(s.user_name),
		game_name = strings.clone(s.game_name),
		title = strings.clone(s.title),
		viewer_count = s.viewer_count,
		started_at = strings.clone(s.started_at),
		thumbnail_url = strings.clone(s.thumbnail_url),
	}
}

destroy_stream :: proc(s: Stream) {
	delete(s.user_id)
	delete(s.user_login)
	delete(s.user_name)
	delete(s.game_name)
	delete(s.title)
	delete(s.started_at)
	delete(s.thumbnail_url)
}

Twitch_Error :: enum {
	None,
	Request_Failed,
	Unauthorized,
	Bad_Status,
	Bad_Json,
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

// A GET from the Helix API. The body is allocated with the temp allocator.
helix_get :: proc(client_id, token, path: string) -> (body: []byte, err: Twitch_Error) {
	headers := []string {
		strings.concatenate({"Client-Id: ", client_id}, context.temp_allocator),
		strings.concatenate({"Authorization: Bearer ", token}, context.temp_allocator),
	}
	url := strings.concatenate({HELIX_URL, path}, context.temp_allocator)
	res, ok := http_request(url, headers, allocator = context.temp_allocator)
	if !ok {
		return nil, .Request_Failed
	}
	switch res.status {
	case 200:
		return res.body, .None
	case 401:
		return nil, .Unauthorized
	case:
		log.warnf("GET %s returned %d: %s", path, res.status, strings.trim_space(string(res.body)))
		return nil, .Bad_Status
	}
}

// Returns the channels in `logins` that are live. Everything is allocated with the
// temp allocator.
get_live_streams :: proc(client_id, token: string, logins: []string) -> (streams: []Stream, err: Twitch_Error) {
	all := make([dynamic]Stream, context.temp_allocator)
	for start := 0; start < len(logins); start += MAX_LOGINS_PER_REQUEST {
		batch := logins[start:min(start + MAX_LOGINS_PER_REQUEST, len(logins))]
		body := helix_get(client_id, token, streams_path(batch)) or_return
		append(&all, ..parse_streams_response(body) or_return)
	}
	return all[:], .None
}

streams_path :: proc(logins: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "/streams?first=100")
	for login in logins {
		strings.write_string(&sb, "&user_login=")
		strings.write_string(&sb, login)
	}
	return strings.to_string(sb)
}

parse_streams_response :: proc(body: []byte) -> (streams: []Stream, err: Twitch_Error) {
	streams, _, err = parse_streams_page(body)
	return
}

// A page of streams and the cursor for the next page ("" on the last). Allocated
// with the temp allocator.
parse_streams_page :: proc(body: []byte) -> (streams: []Stream, cursor: string, err: Twitch_Error) {
	Streams_Response :: struct {
		data:       []Stream,
		pagination: struct {
			cursor: string,
		},
	}
	r: Streams_Response
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, "", .Bad_Json
	}
	return r.data, r.pagination.cursor, .None
}

// The live channels a user follows, most viewers first, allocated with the temp
// allocator. Needs the user:read:follows scope.
get_followed_streams :: proc(client_id, token, user_id: string) -> (streams: []Stream, err: Twitch_Error) {
	all := make([dynamic]Stream, context.temp_allocator)
	cursor := ""
	for {
		path := fmt.tprintf("/streams/followed?user_id=%s&first=100", user_id)
		if cursor != "" {
			path = fmt.tprintf("%s&after=%s", path, cursor)
		}
		body := helix_get(client_id, token, path) or_return
		page: []Stream
		page, cursor = parse_streams_page(body) or_return
		append(&all, ..page)
		if cursor == "" || len(page) == 0 {
			return all[:], .None
		}
	}
}
