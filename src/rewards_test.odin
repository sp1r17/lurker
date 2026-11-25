package app

import "core:testing"

@(private = "file")
messages_from :: proc(line: string) -> [dynamic]Chat_Message {
	msg, _ := parse_irc(line)
	out: [dynamic]Chat_Message
	irc_chat_messages(msg, &out)
	return out
}

@(private = "file")
destroy_messages :: proc(out: [dynamic]Chat_Message) {
	for m in out {
		destroy_chat_message(m)
	}
	delete(out)
}

@(test)
reward_messages_are_labelled :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	out := messages_from("@id=1;custom-reward-id=3eadf8c5-cc1c :alice!alice@x PRIVMSG #chan :add KEKW please")
	defer destroy_messages(out)
	m := &out[0]
	testing.expect_value(t, m.accent, Message_Accent.Reward)
	testing.expect_value(t, m.label, "Redeemed a reward")

	// Once the channel's rewards are known, named.
	rewards: Rewards
	defer rewards_destroy(&rewards)
	body := `{"data":{"channel":{"communityPointsSettings":{"customRewards":[` +
		`{"id":"3eadf8c5-cc1c","title":"Pick a new BTTV/7TV emote"},{"id":"other","title":"Hydrate"}]}}}}`
	ok: bool
	rewards, ok = parse_rewards_response(transmute([]byte)string(body))
	testing.expect(t, ok && rewards.loaded)
	apply_reward_label(&rewards, m)
	testing.expect_value(t, m.label, "Redeemed Pick a new BTTV/7TV emote")
}

@(test)
no_channel_is_no_rewards :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, ok := parse_rewards_response(transmute([]byte)string(`{"data":{"channel":null}}`))
	testing.expect(t, !ok)
	// A channel without channel points still answers: none to name.
	r, has := parse_rewards_response(transmute([]byte)string(`{"data":{"channel":{"communityPointsSettings":null}}}`))
	defer rewards_destroy(&r)
	testing.expect(t, has && len(r.names) == 0)
}

@(test)
highlighted_messages_and_announcements_are_marked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	highlighted := messages_from("@id=2;msg-id=highlighted-message :bob!bob@x PRIVMSG #chan :look at me")
	defer destroy_messages(highlighted)
	testing.expect_value(t, highlighted[0].accent, Message_Accent.Highlighted)
	testing.expect_value(t, highlighted[0].label, "Highlighted message")

	// An announcement is the moderator's message alone, in its colour, without
	// Twitch's system line.
	announced := messages_from("@id=3;login=mod;display-name=Mod;msg-id=announcement;msg-param-color=GREEN;system-msg= :tmi.twitch.tv USERNOTICE #chan :Stream starts at 5")
	defer destroy_messages(announced)
	testing.expect_value(t, len(announced), 1)
	testing.expect_value(t, announced[0].accent, Message_Accent.Announcement_Green)
	testing.expect_value(t, announced[0].label, "Announcement")
	testing.expect_value(t, announced[0].login, "mod")
	testing.expect_value(t, message_plain_text(&announced[0]), "Stream starts at 5")

	primary := messages_from("@id=4;login=mod;msg-id=announcement;msg-param-color=PRIMARY :tmi.twitch.tv USERNOTICE #chan :hi")
	defer destroy_messages(primary)
	testing.expect_value(t, primary[0].accent, Message_Accent.Announcement_Purple)
}
