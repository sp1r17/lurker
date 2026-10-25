package app

import "core:testing"

@(test)
replies_know_their_thread :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	msg, _ := parse_irc(
		"@id=r2;reply-parent-display-name=Bob;reply-parent-msg-body=hi;reply-parent-msg-id=r1;reply-parent-user-login=bob;reply-thread-parent-msg-id=root;reply-thread-parent-user-login=alice :carol!carol@x PRIVMSG #chan :@Bob hello",
	)
	m := privmsg_to_chat(msg)
	defer destroy_chat_message(m)
	testing.expect_value(t, m.reply_parent, "r1")
	testing.expect_value(t, m.thread, "root")

	// Older replies have no thread tag: the parent started it.
	msg, _ = parse_irc("@id=r3;reply-parent-display-name=Bob;reply-parent-msg-body=hi;reply-parent-msg-id=r1;reply-parent-user-login=bob :carol!carol@x PRIVMSG #chan :ok")
	old := privmsg_to_chat(msg)
	defer destroy_chat_message(old)
	testing.expect_value(t, old.thread, "r1")
}

@(test)
own_replies_join_the_thread :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	chat: Chat
	reply := Chat_Reply {
		id     = "0a1b2c3d-0000-4000-8000-000000000001",
		login  = "bob",
		name   = "Bob",
		body   = "hi there",
		thread = "0a1b2c3d-0000-4000-8000-000000000000",
	}
	chat_send(&chat, "hello", reply)
	defer {
		delete(chat.outgoing[0].text)
		delete(chat.outgoing[0].reply_tag)
		delete(chat.outgoing[0].reply_echo)
		delete(chat.outgoing)
	}
	m := own_message("me", "chan", chat.outgoing[0].reply_echo, "hello")
	defer destroy_chat_message(m)
	testing.expect_value(t, m.reply_parent, reply.id)
	testing.expect_value(t, m.thread, reply.thread)
	testing.expect_value(t, m.reply, "Replying to @Bob: hi there")
}
