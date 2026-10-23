package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:slice"
import "core:strings"

TOKEN_URL :: "https://id.twitch.tv/oauth2/token"
HELIX_URL :: "https://api.twitch.tv/helix"
// Twitch's own GraphQL API: the only way to get the categories a user follows.
// Like the Android TV app it signs in as, it takes the same token as Helix.
GQL_URL :: "https://gql.twitch.tv/gql"
// Categories on the browse screen: box art is fetched at this size.
BOX_ART_SIZE :: [2]int{188, 250}
SEARCH_RESULTS :: 40
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

// The most watched live streams on Twitch, or in one category if `game_id` isn't
// "": the first 100, most viewers first. Allocated with the temp allocator.
get_top_streams :: proc(client_id, token: string, game_id := "") -> (streams: []Stream, err: Twitch_Error) {
	path := "/streams?first=100"
	if game_id != "" {
		path = fmt.tprintf("%s&game_id=%s", path, net.percent_encode(game_id, context.temp_allocator))
	}
	body := helix_get(client_id, token, path) or_return
	return parse_streams_response(body)
}

// A category (game), with how many are watching it.
Category :: struct {
	id:          string,
	name:        string,
	viewers:     int,
	box_art_url: string,
}

clone_category :: proc(c: Category) -> Category {
	return {
		id = strings.clone(c.id),
		name = strings.clone(c.name),
		viewers = c.viewers,
		box_art_url = strings.clone(c.box_art_url),
	}
}

destroy_category :: proc(c: Category) {
	delete(c.id)
	delete(c.name)
	delete(c.box_art_url)
}

// A POST to the GraphQL API, with `variables` for the query's $parameters (so
// nothing typed is ever spliced into the query). The body is allocated with the
// temp allocator.
gql_post :: proc(client_id, token, query: string, variables: map[string]string = nil) -> (body: []byte, err: Twitch_Error) {
	request, marshal_err := json.marshal(
		struct {
			query:     string,
			variables: map[string]string,
		}{query, variables},
		allocator = context.temp_allocator,
	)
	if marshal_err != nil {
		return nil, .Bad_Json
	}
	headers := []string {
		strings.concatenate({"Client-Id: ", client_id}, context.temp_allocator),
		"Content-Type: application/json",
		strings.concatenate({"Authorization: OAuth ", token}, context.temp_allocator),
	}
	// Signed out, some lookups still work without it.
	if token == "" {
		headers = headers[:2]
	}
	res, ok := http_request(GQL_URL, headers, post_body = string(request), allocator = context.temp_allocator)
	if !ok {
		return nil, .Request_Failed
	}
	switch res.status {
	case 200:
		return res.body, .None
	case 401:
		return nil, .Unauthorized
	case:
		log.warnf("GraphQL returned %d: %s", res.status, strings.trim_space(string(res.body)))
		return nil, .Bad_Status
	}
}

// What every category query asks for. Concatenated into queries, not formatted:
// fmt reads GraphQL's braces as its own.
@(private = "file")
category_fields :: proc() -> string {
	return fmt.tprintf("id displayName viewersCount boxArtURL(width: %d, height: %d)", BOX_ART_SIZE.x, BOX_ART_SIZE.y)
}

// A page of the most watched categories, after `after` ("" for the first page,
// which also brings the user's followed categories).
categories_query :: proc(after: string) -> string {
	fields := category_fields()
	games := strings.concatenate(
		{" games(first: 100, after: $after) { edges { cursor node { ", fields, " } } pageInfo { hasNextPage } }"},
		context.temp_allocator,
	)
	if after != "" {
		return strings.concatenate({"query($after: Cursor) {", games, " }"}, context.temp_allocator)
	}
	return strings.concatenate(
		{"query($after: Cursor) { currentUser { followedGames(first: 100, type: ALL) { nodes { ", fields, " } } }", games, " }"},
		context.temp_allocator,
	)
}

// Categories, most viewers first: the user's followed ones (first page only) and a
// page of the most watched, with the cursor for the next page ("" if it's the
// last). Allocated with the temp allocator.
get_categories :: proc(
	client_id, token: string,
	after := "",
) -> (
	followed, top: []Category,
	next: string,
	err: Twitch_Error,
) {
	variables := make(map[string]string, context.temp_allocator)
	if after != "" {
		variables["after"] = after
	}
	body := gql_post(client_id, token, categories_query(after), variables) or_return
	return parse_categories_response(body)
}

parse_categories_response :: proc(body: []byte) -> (followed, top: []Category, next: string, err: Twitch_Error) {
	Response :: struct {
		data:   struct {
			currentUser: struct {
				followedGames: struct {
					nodes: []Category_Node,
				},
			},
			games:       struct {
				edges:    []struct {
					cursor: string,
					node:   Category_Node,
				},
				pageInfo: struct {
					hasNextPage: bool,
				},
			},
		},
		errors: []struct {
			message: string,
		},
	}
	r: Response
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, nil, "", .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return nil, nil, "", .Bad_Status
	}
	f := make([dynamic]Category, context.temp_allocator)
	for n in r.data.currentUser.followedGames.nodes {
		append(&f, category_from_node(n))
	}
	sort_by_viewers(f[:])
	t := make([dynamic]Category, context.temp_allocator)
	for e in r.data.games.edges {
		append(&t, category_from_node(e.node))
	}
	// Twitch's order is only roughly by viewers.
	sort_by_viewers(t[:])
	edges := r.data.games.edges
	if r.data.games.pageInfo.hasNextPage && len(edges) > 0 {
		next = edges[len(edges) - 1].cursor
	}
	return f[:], t[:], next, .None
}

// Categories whose names match `query`, best match first. Allocated with the temp
// allocator.
search_categories :: proc(client_id, token, query: string) -> (categories: []Category, err: Twitch_Error) {
	q := strings.concatenate(
		{"query($q: String!) { searchCategories(query: $q, first: ", fmt.tprint(SEARCH_RESULTS), ") { edges { node { ", category_fields(), " } } } }"},
		context.temp_allocator,
	)
	variables := make(map[string]string, context.temp_allocator)
	variables["q"] = query
	body := gql_post(client_id, token, q, variables) or_return
	return parse_category_search_response(body)
}

parse_category_search_response :: proc(body: []byte) -> (categories: []Category, err: Twitch_Error) {
	r: struct {
		data:   struct {
			searchCategories: struct {
				edges: []struct {
					node: Category_Node,
				},
			},
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return nil, .Bad_Status
	}
	found := make([dynamic]Category, context.temp_allocator)
	for e in r.data.searchCategories.edges {
		append(&found, category_from_node(e.node))
	}
	return found[:], .None
}

// A category as GraphQL describes it. A category nobody is watching has a null
// viewersCount, read as 0.
@(private = "file")
Category_Node :: struct {
	id:           string,
	displayName:  string,
	viewersCount: int,
	boxArtURL:    string,
}

@(private = "file")
category_from_node :: proc(n: Category_Node) -> Category {
	return {id = n.id, name = n.displayName, viewers = n.viewersCount, box_art_url = n.boxArtURL}
}

sort_by_viewers :: proc(categories: []Category) {
	slice.stable_sort_by(categories, proc(a, b: Category) -> bool {return a.viewers > b.viewers})
}

// A channel found by searching: live or not.
Channel :: struct {
	id:                string,
	broadcaster_login: string,
	display_name:      string,
	game_name:         string,
	title:             string,
	is_live:           bool,
	// The channel's profile picture.
	thumbnail_url:     string,
	// Not from Helix: whether the user follows it (looked up with get_follows),
	// and whether following or unfollowing it is under way.
	follow:            Follow_State,
	follow_pending:    bool,
}

clone_channel :: proc(c: Channel) -> Channel {
	return {
		id = strings.clone(c.id),
		broadcaster_login = strings.clone(c.broadcaster_login),
		display_name = strings.clone(c.display_name),
		game_name = strings.clone(c.game_name),
		title = strings.clone(c.title),
		is_live = c.is_live,
		thumbnail_url = strings.clone(c.thumbnail_url),
		follow = c.follow,
		follow_pending = c.follow_pending,
	}
}

destroy_channel :: proc(c: Channel) {
	delete(c.id)
	delete(c.broadcaster_login)
	delete(c.display_name)
	delete(c.game_name)
	delete(c.title)
	delete(c.thumbnail_url)
}

// Channels whose names match `query`, as Twitch ranks them (live ones tend to come
// first). Allocated with the temp allocator.
search_channels :: proc(client_id, token, query: string) -> (channels: []Channel, err: Twitch_Error) {
	path := fmt.tprintf("/search/channels?first=%d&query=%s", SEARCH_RESULTS, net.percent_encode(query, context.temp_allocator))
	body := helix_get(client_id, token, path) or_return
	return parse_channels_response(body)
}

parse_channels_response :: proc(body: []byte) -> (channels: []Channel, err: Twitch_Error) {
	r: struct {
		data: []Channel,
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, .Bad_Json
	}
	return r.data, .None
}

// Whether the signed-in user follows `login`, and the channel's user ID, which
// set_follow needs. Helix can't follow or unfollow, so this and set_follow use
// GraphQL.
get_follow :: proc(client_id, token, login: string) -> (user_id: string, following: bool, err: Twitch_Error) {
	variables := make(map[string]string, context.temp_allocator)
	variables["login"] = login
	body := gql_post(client_id, token, "query($login: String!) { user(login: $login) { id self { follower { followedAt } } } }", variables) or_return
	return parse_follow_response(body)
}

parse_follow_response :: proc(body: []byte) -> (user_id: string, following: bool, err: Twitch_Error) {
	r: struct {
		data:   struct {
			user: Maybe(struct {
				id:   string,
				self: struct {
					follower: Maybe(struct {
						followedAt: string,
					}),
				},
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return "", false, .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return "", false, .Bad_Status
	}
	user, found := r.data.user.?
	if !found {
		return "", false, .Bad_Status
	}
	_, following = user.self.follower.?
	return user.id, following, .None
}

// Which of the channels with user IDs `ids` the signed-in user follows, in one
// request. Allocated with the temp allocator.
get_follows :: proc(client_id, token: string, ids: []string) -> (followed: map[string]bool, err: Twitch_Error) {
	// The IDs go into the query itself (variables here are strings only), so only
	// numeric ones are sent.
	list := make([dynamic]string, context.temp_allocator)
	for id in ids {
		if id != "" && strings.trim_left(id, "0123456789") == "" {
			append(&list, fmt.tprintf("\"%s\"", id))
		}
	}
	if len(list) == 0 {
		return make(map[string]bool, context.temp_allocator), .None
	}
	query := strings.concatenate(
		{"query { users(ids: [", strings.join(list[:], ",", context.temp_allocator), "]) { id self { follower { followedAt } } } }"},
		context.temp_allocator,
	)
	body := gql_post(client_id, token, query) or_return
	return parse_follows_response(body)
}

parse_follows_response :: proc(body: []byte) -> (followed: map[string]bool, err: Twitch_Error) {
	r: struct {
		data:   struct {
			users: []Maybe(struct {
				id:   string,
				self: struct {
					follower: Maybe(struct {
						followedAt: string,
					}),
				},
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return nil, .Bad_Status
	}
	followed = make(map[string]bool, context.temp_allocator)
	for maybe_user in r.data.users {
		// A banned or deleted channel is null.
		user := maybe_user.? or_continue
		_, followed[user.id] = user.self.follower.?
	}
	return followed, .None
}

// Follows or unfollows the channel with user ID `user_id`.
set_follow :: proc(client_id, token, user_id: string, follow: bool) -> Twitch_Error {
	variables := make(map[string]string, context.temp_allocator)
	variables["id"] = user_id
	query :=
		"mutation($id: ID!) { followUser(input: {targetID: $id, disableNotifications: false}) { error { code } } }" if follow else "mutation($id: ID!) { unfollowUser(input: {targetID: $id}) { follow { followedAt } } }"
	body := gql_post(client_id, token, query, variables) or_return
	return parse_set_follow_response(body)
}

parse_set_follow_response :: proc(body: []byte) -> Twitch_Error {
	r: struct {
		data:   struct {
			followUser: struct {
				error: Maybe(struct {
					code: string,
				}),
			},
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return .Bad_Status
	}
	if e, failed := r.data.followUser.error.?; failed {
		log.warnf("following failed: %s", e.code)
		return .Bad_Status
	}
	return .None
}

// An emote the signed-in user can use in chat, as GraphQL describes it: its
// name, ID, type ("SUBSCRIPTIONS", "FOLLOWER", "GLOBALS", ...) and channel.
Twitch_User_Emote :: struct {
	token: string,
	id:    string,
	type:  string,
	owner: string,
}

// The emotes the signed-in user can use: global ones, and those from their
// subscriptions, follows and the like. Helix needs a scope the sign-in doesn't
// ask for, so this uses GraphQL. Allocated with the temp allocator.
get_user_emotes :: proc(client_id, token: string) -> (emotes: []Twitch_User_Emote, err: Twitch_Error) {
	body := gql_post(client_id, token, "query { currentUser { emoteSets { owner { login } emotes { id token type } } } }") or_return
	return parse_user_emotes_response(body)
}

parse_user_emotes_response :: proc(body: []byte) -> (emotes: []Twitch_User_Emote, err: Twitch_Error) {
	r: struct {
		data:   struct {
			currentUser: Maybe(struct {
				emoteSets: []struct {
					owner:  Maybe(struct {
						login: string,
					}),
					emotes: []struct {
						id:    string,
						token: string,
						type:  string,
					},
				},
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return nil, .Bad_Status
	}
	user, found := r.data.currentUser.?
	if !found {
		return nil, .Unauthorized
	}
	list := make([dynamic]Twitch_User_Emote, context.temp_allocator)
	for set in user.emoteSets {
		owner := ""
		if o, has_owner := set.owner.?; has_owner {
			owner = o.login
		}
		for e in set.emotes {
			// The old smilies, like ":)", are named by patterns ("\:-?\)"): typing the
			// pattern wouldn't send them.
			if e.token == "" || strings.contains_rune(e.token, '\\') {
				continue
			}
			append(&list, Twitch_User_Emote{e.token, e.id, e.type, owner})
		}
	}
	return list[:], .None
}

// The logins of every channel the user follows, from Helix (GraphQL's list of
// follows is refused). Allocated with the temp allocator.
get_followed_logins :: proc(client_id, token, user_id: string) -> (logins: []string, err: Twitch_Error) {
	all := make([dynamic]string, context.temp_allocator)
	cursor := ""
	for {
		path := fmt.tprintf("/channels/followed?user_id=%s&first=100", user_id)
		if cursor != "" {
			path = fmt.tprintf("%s&after=%s", path, cursor)
		}
		body := helix_get(client_id, token, path) or_return
		page: []string
		page, cursor = parse_followed_logins_page(body) or_return
		append(&all, ..page)
		if cursor == "" || len(page) == 0 {
			return all[:], .None
		}
	}
}

parse_followed_logins_page :: proc(body: []byte) -> (logins: []string, cursor: string, err: Twitch_Error) {
	r: struct {
		data:       []struct {
			broadcaster_login: string,
		},
		pagination: struct {
			cursor: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, "", .Bad_Json
	}
	list := make([]string, len(r.data), context.temp_allocator)
	for d, i in r.data {
		list[i] = d.broadcaster_login
	}
	return list, r.pagination.cursor, .None
}

// A channel the user follows, live or not, and when it last streamed.
Followed_Channel :: struct {
	login:        string,
	display_name: string,
	avatar_url:   string,
	live:         bool,
	// RFC 3339 ("" if it never has), and what it streamed.
	last_live:    string,
	last_game:    string,
}

clone_followed_channel :: proc(c: Followed_Channel) -> Followed_Channel {
	return {
		login = strings.clone(c.login),
		display_name = strings.clone(c.display_name),
		avatar_url = strings.clone(c.avatar_url),
		live = c.live,
		last_live = strings.clone(c.last_live),
		last_game = strings.clone(c.last_game),
	}
}

destroy_followed_channel :: proc(c: Followed_Channel) {
	delete(c.login)
	delete(c.display_name)
	delete(c.avatar_url)
	delete(c.last_live)
	delete(c.last_game)
}

// How many channels one GraphQL lookup asks about.
CHANNEL_STATUS_BATCH :: 100

// Whether each of `logins` is live, and when it last was, from GraphQL in
// batches. Unknown or banned channels are left out. Allocated with the temp
// allocator.
get_channel_status :: proc(client_id, token: string, logins: []string) -> (channels: []Followed_Channel, err: Twitch_Error) {
	all := make([dynamic]Followed_Channel, context.temp_allocator)
	for start := 0; start < len(logins); start += CHANNEL_STATUS_BATCH {
		batch := logins[start:min(start + CHANNEL_STATUS_BATCH, len(logins))]
		// Logins go into the query itself (variables here are strings only), so
		// only valid ones are sent.
		quoted := make([dynamic]string, context.temp_allocator)
		for login in batch {
			if valid_login(login) {
				append(&quoted, fmt.tprintf("\"%s\"", login))
			}
		}
		if len(quoted) == 0 {
			continue
		}
		query := strings.concatenate(
			{
				"query { users(logins: [",
				strings.join(quoted[:], ",", context.temp_allocator),
				"]) { login displayName profileImageURL(width: 70) stream { id } lastBroadcast { startedAt game { displayName } } } }",
			},
			context.temp_allocator,
		)
		body := gql_post(client_id, token, query) or_return
		page := parse_channel_status_response(body) or_return
		append(&all, ..page)
	}
	return all[:], .None
}

parse_channel_status_response :: proc(body: []byte) -> (channels: []Followed_Channel, err: Twitch_Error) {
	r: struct {
		data:   struct {
			users: []Maybe(struct {
				login:           string,
				displayName:     string,
				profileImageURL: string,
				stream:          Maybe(struct {
					id: string,
				}),
				lastBroadcast:   Maybe(struct {
					startedAt: string,
					game:      Maybe(struct {
						displayName: string,
					}),
				}),
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return nil, .Bad_Status
	}
	list := make([dynamic]Followed_Channel, context.temp_allocator)
	for maybe_user in r.data.users {
		u := maybe_user.? or_continue
		c := Followed_Channel {
			login        = u.login,
			display_name = u.displayName,
			avatar_url   = u.profileImageURL,
		}
		_, c.live = u.stream.?
		if last, has_last := u.lastBroadcast.?; has_last {
			c.last_live = last.startedAt
			if game, has_game := last.game.?; has_game {
				c.last_game = game.displayName
			}
		}
		append(&list, c)
	}
	return list[:], .None
}

// A past broadcast (VOD).
Vod :: struct {
	id:         string,
	title:      string,
	game:       string,
	// RFC 3339.
	created_at: string,
	length:     int,
}

clone_vod :: proc(v: Vod) -> Vod {
	return {strings.clone(v.id), strings.clone(v.title), strings.clone(v.game), strings.clone(v.created_at), v.length}
}

destroy_vod :: proc(v: Vod) {
	delete(v.id)
	delete(v.title)
	delete(v.game)
	delete(v.created_at)
}

// `login`'s most recent past broadcast, if it has one. Allocated with the temp
// allocator.
get_latest_vod :: proc(client_id, token, login: string) -> (vod: Vod, found: bool, err: Twitch_Error) {
	variables := make(map[string]string, context.temp_allocator)
	variables["login"] = login
	body := gql_post(
		client_id,
		token,
		"query($login: String!) { user(login: $login) { videos(first: 1, type: ARCHIVE, sort: TIME) { edges { node { id title lengthSeconds createdAt game { displayName } } } } } }",
		variables,
	) or_return
	return parse_latest_vod_response(body)
}

parse_latest_vod_response :: proc(body: []byte) -> (vod: Vod, found: bool, err: Twitch_Error) {
	r: struct {
		data:   struct {
			user: Maybe(struct {
				videos: Maybe(struct {
					edges: []struct {
						node: struct {
							id:            string,
							title:         string,
							lengthSeconds: int,
							createdAt:     string,
							game:          Maybe(struct {
								displayName: string,
							}),
						},
					},
				}),
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return {}, false, .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return {}, false, .Bad_Status
	}
	user, has_user := r.data.user.?
	if !has_user {
		return {}, false, .None
	}
	videos, has_videos := user.videos.?
	if !has_videos || len(videos.edges) == 0 {
		return {}, false, .None
	}
	n := videos.edges[0].node
	vod = {id = n.id, title = n.title, created_at = n.createdAt, length = n.lengthSeconds}
	if game, has_game := n.game.?; has_game {
		vod.game = game.displayName
	}
	return vod, true, .None
}

// A message from a past broadcast's chat, as a chat message, and when in the
// broadcast it was sent.
Replay_Message :: struct {
	offset:  int,
	message: Chat_Message,
}

// A batch of past broadcast `vod_id`'s chat (about 30 seconds of it): from
// `offset` seconds in, or after `cursor` if it isn't "". `next` is the cursor for
// the batch after ("" at the end). The messages are owned; the rest is
// allocated with the temp allocator.
get_vod_comments :: proc(
	client_id, token, vod_id: string,
	offset: int,
	cursor := "",
) -> (
	messages: [dynamic]Replay_Message,
	next: string,
	err: Twitch_Error,
) {
	FIELDS :: "edges { cursor node { id contentOffsetSeconds commenter { login displayName } message { userColor userBadges { setID version } fragments { text emote { emoteID } } } } } pageInfo { hasNextPage }"
	variables := make(map[string]string, context.temp_allocator)
	variables["id"] = vod_id
	query: string
	if cursor != "" {
		variables["cursor"] = cursor
		query = "query($id: ID!, $cursor: Cursor) { video(id: $id) { comments(after: $cursor) { " + FIELDS + " } } }"
	} else {
		// A number, so it can go into the query itself.
		query = strings.concatenate(
			{"query($id: ID!) { video(id: $id) { comments(contentOffsetSeconds: ", fmt.tprint(max(offset, 0)), ") { ", FIELDS, " } } }"},
			context.temp_allocator,
		)
	}
	body := gql_post(client_id, token, query, variables) or_return
	return parse_vod_comments_response(body)
}

parse_vod_comments_response :: proc(body: []byte) -> (messages: [dynamic]Replay_Message, next: string, err: Twitch_Error) {
	r: struct {
		data:   struct {
			video: Maybe(struct {
				comments: Maybe(struct {
					edges:    []struct {
						cursor: string,
						node:   struct {
							id:                   string,
							contentOffsetSeconds: int,
							commenter:            Maybe(struct {
								login:       string,
								displayName: string,
							}),
							message:              struct {
								userColor:  string,
								userBadges: []struct {
									setID:   string,
									version: string,
								},
								fragments:  []struct {
									text:  string,
									emote: Maybe(struct {
										emoteID: string,
									}),
								},
							},
						},
					},
					pageInfo: struct {
						hasNextPage: bool,
					},
				}),
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return nil, "", .Bad_Json
	}
	if len(r.errors) > 0 {
		log.warnf("GraphQL error: %s", r.errors[0].message)
		return nil, "", .Bad_Status
	}
	video, has_video := r.data.video.?
	if !has_video {
		return nil, "", .Bad_Status
	}
	comments, has_comments := video.comments.?
	if !has_comments {
		return nil, "", .Bad_Status
	}
	for e in comments.edges {
		n := e.node
		// A deleted account's messages have no sender.
		commenter := n.commenter.? or_continue
		name := commenter.displayName if commenter.displayName != "" else commenter.login
		if strings.to_lower(name, context.temp_allocator) != commenter.login {
			name = strings.concatenate({name, " (", commenter.login, ")"}, context.temp_allocator)
		}
		color, color_ok := parse_hex_color(n.message.userColor)
		if !color_ok {
			color = default_name_color(commenter.login)
		}
		m := Chat_Message {
			kind  = .Chat,
			name  = strings.clone(name),
			color = readable_on_dark(color),
			id    = strings.clone(n.id),
			login = strings.clone(commenter.login),
		}
		for b in n.message.userBadges {
			if b.setID != "" {
				append(&m.badges, fmt.aprintf("%s/%s", b.setID, b.version))
			}
		}
		for f in n.message.fragments {
			if emote, is_emote := f.emote.?; is_emote && emote.emoteID != "" {
				append(
					&m.fragments,
					Fragment {
						kind = .Emote,
						text = strings.clone(strings.trim_space(f.text)),
						url_1x = fmt.aprintf(TWITCH_EMOTE_URL, emote.emoteID, "1.0"),
						url_2x = fmt.aprintf(TWITCH_EMOTE_URL, emote.emoteID, "2.0"),
					},
				)
			} else if f.text != "" {
				append(&m.fragments, Fragment{kind = .Text, text = strings.clone(f.text)})
			}
		}
		append(&messages, Replay_Message{n.contentOffsetSeconds, m})
	}
	if comments.pageInfo.hasNextPage && len(comments.edges) > 0 {
		next = comments.edges[len(comments.edges) - 1].cursor
	}
	return messages, next, .None
}
