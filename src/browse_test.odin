package app

import "core:testing"
import "core:time"

@(test)
viewer_counts_read_like_twitch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, format_viewers(999), "999")
	testing.expect_value(t, format_viewers(1000), "1K")
	testing.expect_value(t, format_viewers(1234), "1.2K")
	testing.expect_value(t, format_viewers(25_100), "25.1K")
	testing.expect_value(t, format_viewers(2_000_000), "2M")
}

@(test)
streams_page_has_cursor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":[{"user_id":"1","user_login":"lirik","user_name":"LIRIK","game_name":"G","title":"T",` +
		`"viewer_count":11300,"thumbnail_url":"https://x/live_user_lirik-{width}x{height}.jpg"}],` +
		`"pagination":{"cursor":"abc"}}`
	streams, cursor, err := parse_streams_page(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, cursor, "abc")
	testing.expect_value(t, len(streams), 1)
	testing.expect_value(t, streams[0].thumbnail_url, "https://x/live_user_lirik-{width}x{height}.jpg")

	_, last_cursor, _ := parse_streams_page(transmute([]byte)string(`{"data":[],"pagination":{}}`))
	testing.expect_value(t, last_cursor, "")
}

@(test)
uptime_reads_as_hours_minutes_seconds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	now, _ := time.rfc3339_to_time_utc("2026-10-20T15:05:09Z")
	text, ok := format_uptime("2026-10-20T13:00:00Z", now)
	testing.expect(t, ok)
	testing.expect_value(t, text, "2:05:09")
	_, bad := format_uptime("yesterday", now)
	testing.expect(t, !bad)
}

@(test)
categories_query_pages :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	FIELDS :: "id displayName viewersCount boxArtURL(width: 188, height: 250)"
	GAMES :: " games(first: 100, after: $after) { edges { cursor node { " + FIELDS + " } } pageInfo { hasNextPage } }"
	// The first page brings the followed categories too; later ones don't.
	testing.expect_value(
		t,
		categories_query(""),
		"query($after: Cursor) { currentUser { followedGames(first: 100, type: ALL) { nodes { " + FIELDS + " } } }" + GAMES + " }",
	)
	testing.expect_value(t, categories_query("abc"), "query($after: Cursor) {" + GAMES + " }")
}

@(test)
categories_read_followed_and_top :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"currentUser":{"followedGames":{"nodes":[` +
		`{"id":"1","displayName":"Retro","viewersCount":50,"boxArtURL":"https://x/1-188x250.jpg"},` +
		`{"id":"2","displayName":"Deadlock","viewersCount":4000,"boxArtURL":"https://x/2-188x250.jpg"}]}},` +
		`"games":{"edges":[{"cursor":"c1","node":{"id":"7","displayName":"Pokémon","viewersCount":2417}},` +
		`{"cursor":"c2","node":{"id":"509658","displayName":"Just Chatting","viewersCount":363815,"boxArtURL":"https://x/3.jpg"}}],` +
		`"pageInfo":{"hasNextPage":true}}}}`
	followed, top, next, err := parse_categories_response(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, len(followed), 2)
	// Most viewers first, whatever order Twitch gave.
	testing.expect_value(t, followed[0].name, "Deadlock")
	testing.expect_value(t, followed[1].viewers, 50)
	testing.expect_value(t, len(top), 2)
	testing.expect_value(t, top[0].id, "509658")
	// The next page starts after the last edge as Twitch sent them.
	testing.expect_value(t, next, "c2")

	last := `{"data":{"games":{"edges":[{"cursor":"c9","node":{"id":"9","displayName":"Q","viewersCount":null}}],"pageInfo":{"hasNextPage":false}}}}`
	_, last_top, last_next, last_err := parse_categories_response(transmute([]byte)last)
	testing.expect_value(t, last_err, Twitch_Error.None)
	testing.expect_value(t, last_next, "")
	testing.expect_value(t, last_top[0].viewers, 0)

	_, _, _, gql_err := parse_categories_response(transmute([]byte)string(`{"errors":[{"message":"bad"}]}`))
	testing.expect_value(t, gql_err, Twitch_Error.Bad_Status)
}

@(test)
category_search_keeps_twitch_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"searchCategories":{"edges":[` +
		`{"node":{"id":"512953","displayName":"ELDEN RING","viewersCount":34063,"boxArtURL":"https://x/a.jpg"}},` +
		`{"node":{"id":"511078","displayName":"Elden: Path of the Forgotten","viewersCount":null,"boxArtURL":"https://x/b.jpg"}},` +
		`{"node":{"id":"982348888","displayName":"ELDEN RING NIGHTREIGN","viewersCount":1005}}]}}}`
	found, err := parse_category_search_response(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, len(found), 3)
	// Best match first, not most viewers.
	testing.expect_value(t, found[1].name, "Elden: Path of the Forgotten")
	testing.expect_value(t, found[1].viewers, 0)
}

@(test)
channel_search_reads_live_and_offline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":[{"broadcaster_login":"moonmoon","display_name":"MOONMOON","game_name":"Games + Demos",` +
		`"is_live":false,"thumbnail_url":"https://x/p.png","title":"T","started_at":""},` +
		`{"broadcaster_login":"lirik","display_name":"LIRIK","is_live":true,"title":"U"}]}`
	channels, err := parse_channels_response(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, len(channels), 2)
	testing.expect_value(t, channels[0].display_name, "MOONMOON")
	testing.expect(t, !channels[0].is_live)
	testing.expect(t, channels[1].is_live)
}

@(test)
channel_label_adds_login_when_name_differs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, channel_label({broadcaster_login = "moonmoon", display_name = "MOONMOON"}), "MOONMOON")
	testing.expect_value(t, channel_label({broadcaster_login = "moondogs_celestial", display_name = "幻月_"}), "幻月_ (moondogs_celestial)")
	testing.expect_value(t, channel_label({broadcaster_login = "lirik"}), "lirik")
}

@(test)
follow_reads_following_and_not :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	yes := `{"data":{"user":{"id":"121059319","self":{"follower":{"followedAt":"2017-10-16T23:04:35Z"}}}}}`
	id, following, err := parse_follow_response(transmute([]byte)yes)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, id, "121059319")
	testing.expect(t, following)
	no := `{"data":{"user":{"id":"5","self":{"follower":null}}}}`
	_, following, err = parse_follow_response(transmute([]byte)no)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect(t, !following)
	_, _, err = parse_follow_response(transmute([]byte)string(`{"data":{"user":null}}`))
	testing.expect_value(t, err, Twitch_Error.Bad_Status)
}

@(test)
set_follow_reports_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ok := `{"data":{"followUser":{"error":null}}}`
	testing.expect_value(t, parse_set_follow_response(transmute([]byte)ok), Twitch_Error.None)
	unfollowed := `{"data":{"unfollowUser":{"follow":null}}}`
	testing.expect_value(t, parse_set_follow_response(transmute([]byte)unfollowed), Twitch_Error.None)
	failed := `{"data":{"followUser":{"error":{"code":"TOO_MANY_FOLLOWS"}}}}`
	testing.expect_value(t, parse_set_follow_response(transmute([]byte)failed), Twitch_Error.Bad_Status)
}

@(test)
follows_read_several_channels :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"users":[{"id":"121059319","self":{"follower":{"followedAt":"2017-10-16T23:04:35Z"}}},` +
		`null,{"id":"12826","self":{"follower":null}}]}}`
	followed, err := parse_follows_response(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, len(followed), 2)
	testing.expect(t, followed["121059319"])
	testing.expect(t, !followed["12826"])
}

@(test)
followed_channels_read_status :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	logins, cursor, err := parse_followed_logins_page(
		transmute([]byte)string(`{"total":2,"data":[{"broadcaster_login":"moonmoon"},{"broadcaster_login":"lirik"}],"pagination":{"cursor":"abc"}}`),
	)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, len(logins), 2)
	testing.expect_value(t, cursor, "abc")

	body := `{"data":{"users":[` +
		`{"login":"moonmoon","displayName":"MOONMOON","profileImageURL":"https://x/m.png","stream":null,` +
		`"lastBroadcast":{"startedAt":"2026-10-23T05:13:48Z","game":{"displayName":"Games + Demos"}}},` +
		`null,{"login":"lirik","displayName":"LIRIK","profileImageURL":"","stream":{"id":"1"},"lastBroadcast":null}]}}`
	channels, status_err := parse_channel_status_response(transmute([]byte)body)
	testing.expect_value(t, status_err, Twitch_Error.None)
	testing.expect_value(t, len(channels), 2)
	testing.expect(t, !channels[0].live)
	testing.expect_value(t, channels[0].last_game, "Games + Demos")
	testing.expect(t, channels[1].live)
	testing.expect_value(t, channels[1].last_live, "")
}

@(test)
last_live_reads_naturally :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	now, _ := time.rfc3339_to_time_utc("2026-10-23T12:00:00Z")
	testing.expect_value(t, format_last_live("2026-10-23T11:59:30Z", now), "Live just now")
	testing.expect_value(t, format_last_live("2026-10-23T07:00:00.696673Z", now), "Live 5 hours ago")
	testing.expect_value(t, format_last_live("2026-10-22T11:00:00Z", now), "Live 1 day ago")
	testing.expect_value(t, format_last_live("2026-06-01T00:00:00Z", now), "Live 4 months ago")
	testing.expect_value(t, format_last_live("", now), "Not live recently")

	channels := []Followed_Channel{{login = "a"}, {login = "b", last_live = "2026-10-01T00:00:00Z"}, {login = "c", last_live = "2026-10-20T00:00:00.123Z"}}
	sort_by_last_live(channels)
	testing.expect_value(t, channels[0].login, "c")
	testing.expect_value(t, channels[2].login, "a")
}

@(test)
latest_vod_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"user":{"videos":{"edges":[{"node":{"id":"2908012950","title":"SLOPTOBER 21","lengthSeconds":24205,` +
		`"createdAt":"2026-10-22T22:30:13Z","game":{"displayName":"Games + Demos"}}}]}}}}`
	vod, found, err := parse_latest_vod_response(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect(t, found)
	testing.expect_value(t, vod.id, "2908012950")
	testing.expect_value(t, vod.length, 24205)
	testing.expect_value(t, vod.game, "Games + Demos")
	_, found, err = parse_latest_vod_response(transmute([]byte)string(`{"data":{"user":{"videos":{"edges":[]}}}}`))
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect(t, !found)
}

@(test)
vod_comments_become_chat_messages :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"video":{"comments":{"edges":[` +
		`{"cursor":"c1","node":{"id":"a","contentOffsetSeconds":3594,"commenter":{"login":"rocketpenguin","displayName":"rocketpenguin"},` +
		`"message":{"userColor":"#00FF7F","userBadges":[{"setID":"subscriber","version":"12"},{"setID":"","version":""}],` +
		`"fragments":[{"text":"hi ","emote":null},{"text":"Kappa","emote":{"emoteID":"25"}}]}}},` +
		`{"cursor":"c2","node":{"id":"b","contentOffsetSeconds":3600,"commenter":null,"message":{"userColor":null,"userBadges":[],"fragments":[]}}}` +
		`],"pageInfo":{"hasNextPage":true}}}}}`
	messages, next, err := parse_vod_comments_response(transmute([]byte)body)
	defer {
		for m in messages {
			destroy_chat_message(m.message)
		}
		delete(messages)
	}
	testing.expect_value(t, err, Twitch_Error.None)
	// The deleted account's message is left out.
	testing.expect_value(t, len(messages), 1)
	testing.expect_value(t, next, "c2")
	m := messages[0]
	testing.expect_value(t, m.offset, 3594)
	testing.expect_value(t, m.message.badges[0], "subscriber/12")
	testing.expect_value(t, len(m.message.badges), 1)
	testing.expect_value(t, m.message.fragments[1].kind, Fragment_Kind.Emote)
	testing.expect_value(t, m.message.fragments[1].url_1x, "https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/1.0")
}
