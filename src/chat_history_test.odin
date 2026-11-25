package app

import "core:strings"
import "core:testing"

@(test)
history_is_parsed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"messages":[
		"@id=h1;historical=1 :alice!alice@x PRIVMSG #chan :hello",
		"@historical=1 :tmi.twitch.tv NOTICE #chan :not for us",
		"@id=h2;system-msg=bob\\ssubscribed! :tmi.twitch.tv USERNOTICE #chan",
		"@ban-duration=60 :tmi.twitch.tv CLEARCHAT #chan :alice"
	],"error":null}`
	messages: [dynamic]Chat_Message
	defer {
		for m in messages {
			destroy_chat_message(m)
		}
		delete(messages)
	}
	testing.expect(t, parse_history(transmute([]byte)string(body), &messages))
	testing.expect_value(t, len(messages), 3)
	testing.expect_value(t, messages[0].login, "alice")
	testing.expect_value(t, messages[1].fragments[0].text, "bob subscribed!")
	testing.expect_value(t, messages[2].clear, Clear_Kind.User)
	for m in messages {
		testing.expect(t, m.historical)
	}
}

@(private = "file")
chat :: proc(line: string) -> Chat_Message {
	msg, _ := parse_irc(line)
	return privmsg_to_chat(msg)
}

@(test)
history_goes_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	assets: Assets
	defer emotes_destroy(&assets.emotes)
	v: Chat_View
	defer chat_view_destroy(&v)
	live := []Chat_Message{chat("@id=m2 :b!b@x PRIVMSG #chan :two"), chat("@id=m3 :c!c@x PRIVMSG #chan :three")}
	chat_view_add(&v, &assets, 1, 300, live)
	// m2 arrived live as well: shown once.
	older := []Chat_Message{chat("@id=m1 :a!a@x PRIVMSG #chan :one @me"), chat("@id=m2 :b!b@x PRIVMSG #chan :two")}
	chat_view_prepend(&v, &assets, 1, 300, older, "me")
	testing.expect_value(t, len(v.messages), 3)
	testing.expect_value(t, v.messages[0].id, "m1")
	testing.expect_value(t, v.messages[1].id, "m2")
	testing.expect_value(t, v.messages[2].id, "m3")
	testing.expect(t, v.messages[0].mention)
}

@(test)
emotes_apply_again :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	assets: Assets
	defer emotes_destroy(&assets.emotes)
	channel: Emotes
	defer emotes_destroy(&channel)
	v := Chat_View {
		emotes = &channel,
	}
	defer chat_view_destroy(&v)
	chat_view_add(&v, &assets, 1, 300, []Chat_Message{chat("@id=m1 :a!a@x PRIVMSG #chan :hi KEKW there")})
	testing.expect_value(t, len(v.messages[0].fragments), 1)

	set := make(map[string]Emote)
	set[strings.clone("KEKW")] = {url_1x = strings.clone("https://x/1"), url_2x = strings.clone("https://x/2")}
	channel.sets[.Channel_7TV] = set
	chat_view_refresh_emotes(&v, &assets)
	f := v.messages[0].fragments
	testing.expect_value(t, len(f), 3)
	testing.expect_value(t, f[1].kind, Fragment_Kind.Emote)
	testing.expect_value(t, f[2].text, "there")
}

// The "More messages below" bar takes clicks and hovering over the messages it
// covers.
@(test)
more_bar_covers_messages :: proc(t: ^testing.T) {
	v: Chat_View
	defer chat_view_destroy(&v)
	under := Rect{0, 90, 100, 20}
	append(&v.name_hits, Name_Hit{under, "someone"})
	append(&v.link_hits, Link_Hit{under, "https://example.com"})
	append(&v.reply_hits, under)
	append(&v.message_hits, Message_Hit{rect = under, index = 0})
	v.scroll = 50
	v.more_bar = {0, 80, 100, 30}

	_, name := chat_view_name_at(&v, 50, 95)
	testing.expect(t, !name)
	_, link := chat_view_link_at(&v, 50, 95)
	testing.expect(t, !link)
	testing.expect(t, !chat_view_reply_at(&v, 50, 95))
	testing.expect(t, chat_view_click(&v, 50, 95))
	testing.expect_value(t, v.scroll, 0)

	v.more_bar = {}
	login, found := chat_view_name_at(&v, 50, 95)
	testing.expect(t, found)
	testing.expect_value(t, login, "someone")
}

// The top message can be partly under the header or the pinned message: a click
// there is theirs, not the hidden part of the message's.
@(test)
hidden_part_of_a_message_isnt_clickable :: proc(t: ^testing.T) {
	v: Chat_View
	defer chat_view_destroy(&v)
	// The messages show from y = 100 down; this one starts at 80.
	v.visible = {0, 100, 300, 400}
	name := Rect{10, 82, 60, 16}
	link := Rect{80, 104, 90, 16}
	append(&v.name_hits, Name_Hit{name, "someone"})
	append(&v.link_hits, Link_Hit{link, "https://example.com"})
	append(&v.reply_hits, name)
	append(&v.message_hits, Message_Hit{rect = {0, 80, 300, 40}, index = 0})
	append(&v.messages, Chat_Message{})

	_, on_name := chat_view_name_at(&v, 20, 90)
	testing.expect(t, !on_name)
	testing.expect(t, !chat_view_reply_at(&v, 20, 90))
	_, on_message := chat_view_message_at(&v, 150, 90)
	testing.expect(t, !on_message)
	// What shows is still clickable.
	_, on_link := chat_view_link_at(&v, 100, 110)
	testing.expect(t, on_link)
	_, below := chat_view_message_at(&v, 150, 110)
	testing.expect(t, below)
}
