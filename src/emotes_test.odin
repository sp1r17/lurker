package app

import "core:strings"
import "core:testing"

@(private = "file")
destroy_named :: proc(list: [dynamic]Named_Emote) {
	for e in list {
		delete(e.name)
		delete(e.emote.url_1x)
		delete(e.emote.url_2x)
	}
	delete(list)
}

@(test)
twitch_emotes_split_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	fragments: [dynamic]Fragment
	defer {
		destroy_fragments(fragments[:])
		delete(fragments)
	}
	// Ranges count characters: "é" is two bytes but one character.
	twitch_emote_fragments("é Kappa hi Kappa", "25:2-6,11-15", &fragments)
	testing.expect_value(t, len(fragments), 4)
	testing.expect_value(t, fragments[0].kind, Fragment_Kind.Text)
	testing.expect_value(t, fragments[0].text, "é ")
	testing.expect_value(t, fragments[1].kind, Fragment_Kind.Emote)
	testing.expect_value(t, fragments[1].text, "Kappa")
	testing.expect_value(t, fragments[1].url_1x, "https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/1.0")
	testing.expect_value(t, fragments[2].text, " hi ")
	testing.expect_value(t, fragments[3].kind, Fragment_Kind.Emote)
}

@(test)
twitch_emote_ranges_past_the_end_are_ignored :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	fragments: [dynamic]Fragment
	defer {
		destroy_fragments(fragments[:])
		delete(fragments)
	}
	twitch_emote_fragments("hi", "25:0-9", &fragments)
	testing.expect_value(t, len(fragments), 1)
	testing.expect_value(t, fragments[0].text, "hi")
}

@(test)
third_party_emotes_replace_words :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	emotes: Emotes
	defer emotes_destroy(&emotes)
	list: [dynamic]Named_Emote
	defer delete(list)
	testing.expect(t, parse_emote_set(.Global_BTTV, transmute([]byte)string(`[{"id":"abc","code":"catJAM"}]`), &list))
	job := Emote_Set_Job {
		source = .Global_BTTV,
		emotes = list,
	}
	finish_emote_set_job(&emotes, &job)

	m := system_message("x")
	defer destroy_chat_message(m)
	m.kind = .Chat
	destroy_fragments(m.fragments[:])
	clear(&m.fragments)
	append(&m.fragments, Fragment{kind = .Text, text = strings.clone("so catJAM good")})
	apply_third_party_emotes(&m, nil, &emotes)
	testing.expect_value(t, len(m.fragments), 3)
	testing.expect_value(t, m.fragments[0].text, "so")
	testing.expect_value(t, m.fragments[1].kind, Fragment_Kind.Emote)
	testing.expect_value(t, m.fragments[1].url_2x, "https://cdn.betterttv.net/emote/abc/2x")
	testing.expect_value(t, m.fragments[2].text, "good")
}

@(test)
seventv_sets_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	list: [dynamic]Named_Emote
	defer destroy_named(list)
	body := `{"emote_set":{"emotes":[{"name":"PETPET","flags":1,"data":{"host":{"url":"//cdn.7tv.app/emote/X"}}}]}}`
	testing.expect(t, parse_emote_set(.Channel_7TV, transmute([]byte)body, &list))
	testing.expect_value(t, len(list), 1)
	testing.expect_value(t, list[0].name, "PETPET")
	testing.expect(t, list[0].emote.zero_width)
	testing.expect_value(t, list[0].emote.url_1x, "https://cdn.7tv.app/emote/X/1x.webp")
}

@(test)
bttv_channel_and_ffz_sets_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	list: [dynamic]Named_Emote
	defer destroy_named(list)
	bttv := `{"channelEmotes":[{"id":"a","code":"A"}],"sharedEmotes":[{"id":"b","code":"B"}]}`
	testing.expect(t, parse_emote_set(.Channel_BTTV, transmute([]byte)bttv, &list))
	ffz := `[{"code":"F","images":{"1x":"https://x/1","2x":"https://x/2","4x":null}}]`
	testing.expect(t, parse_emote_set(.Global_FFZ, transmute([]byte)ffz, &list))
	testing.expect_value(t, len(list), 3)
	testing.expect_value(t, list[1].name, "B")
	testing.expect_value(t, list[2].emote.url_2x, "https://x/2")
	testing.expect(t, !parse_emote_set(.Global_FFZ, transmute([]byte)string(`{"error":1}`), &list))
}

@(test)
badges_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	list: [dynamic]Named_Badge
	defer destroy_named_badges(&list)
	body := `{"data":[{"set_id":"subscriber","versions":[{"id":"12","image_url_1x":"u1","image_url_2x":"u2","title":"1-Year Subscriber"}]}]}`
	testing.expect(t, parse_badges(transmute([]byte)body, &list))
	testing.expect_value(t, len(list), 1)
	testing.expect_value(t, list[0].key, "subscriber/12")
	testing.expect_value(t, list[0].badge.url_2x, "u2")
	testing.expect_value(t, list[0].badge.title, "1-Year Subscriber")
}

@(test)
picker_lists_prefix_matches_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Only read, so the maps can borrow constant strings.
	channel, global: Emotes
	channel.sets[.Channel_7TV] = make(map[string]Emote, context.temp_allocator)
	global.sets[.Global_BTTV] = make(map[string]Emote, context.temp_allocator)
	channel.sets[.Channel_7TV]["catJAM"] = {url_1x = "c7"}
	channel.sets[.Channel_7TV]["xddCat"] = {}
	global.sets[.Global_BTTV]["catJAM"] = {url_1x = "gb"}
	global.sets[.Global_BTTV]["Catdance"] = {}
	global.sets[.Global_BTTV]["KEKW"] = {}
	user := make(User_Emotes, context.temp_allocator)
	user["catW"] = {label = "moonmoon"}
	user["catFollow"] = {owner = "other", follower_only = true}
	matches := emote_picker_matches(&user, "moonmoon", &channel, &global, "CAT")
	testing.expect_value(t, len(matches), 4)
	// Prefix matches, shortest first, then the rest; follower emotes only in
	// their own channel.
	testing.expect_value(t, matches[0].name, "catW")
	testing.expect_value(t, matches[0].label, "moonmoon")
	testing.expect_value(t, matches[1].name, "catJAM")
	testing.expect_value(t, matches[1].emote.url_1x, "c7")
	testing.expect_value(t, matches[1].label, "7TV")
	testing.expect_value(t, matches[2].name, "Catdance")
	testing.expect_value(t, matches[3].name, "xddCat")
}

@(test)
user_emotes_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"currentUser":{"emoteSets":[` +
		`{"owner":{"login":"moonmoon"},"emotes":[{"id":"1","token":"moon2L","type":"SUBSCRIPTIONS"}]},` +
		`{"owner":null,"emotes":[{"id":"2","token":"Kappa","type":"GLOBALS"},{"id":"3","token":"\\:-?\\)","type":"SMILIES"}]}]}}}`
	emotes, err := parse_user_emotes_response(transmute([]byte)body)
	testing.expect_value(t, err, Twitch_Error.None)
	testing.expect_value(t, len(emotes), 2)
	testing.expect_value(t, emotes[0].owner, "moonmoon")
	testing.expect_value(t, emotes[1].token, "Kappa")
	testing.expect_value(t, emotes[1].owner, "")
}

@(test)
panel_groups_emotes_by_source :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	channel, global: Emotes
	channel.sets[.Channel_7TV] = make(map[string]Emote, context.temp_allocator)
	global.sets[.Global_BTTV] = make(map[string]Emote, context.temp_allocator)
	channel.sets[.Channel_7TV]["catJAM"] = {}
	global.sets[.Global_BTTV]["catJAM"] = {}
	global.sets[.Global_BTTV]["KEKW"] = {}
	user := make(User_Emotes, context.temp_allocator)
	user["Kappa"] = {label = "Twitch"}
	user["moon2L"] = {label = "moonmoon", owner = "moonmoon"}
	user["zzz"] = {label = "other follower", owner = "other", follower_only = true}
	sections := emote_panel_sections(&user, "moonmoon", &channel, &global)
	// The channel's own first, then Twitch's, then third-party; no follower emotes
	// from elsewhere, and a shared name only once.
	testing.expect_value(t, len(sections), 4)
	testing.expect_value(t, sections[0].label, "moonmoon")
	testing.expect_value(t, sections[1].label, "Twitch")
	testing.expect_value(t, sections[2].label, "7TV")
	testing.expect_value(t, sections[3].label, "BTTV global")
	testing.expect_value(t, len(sections[3].items), 1)
	testing.expect_value(t, sections[3].items[0].name, "KEKW")
}
