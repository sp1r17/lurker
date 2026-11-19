package app

import "core:strings"
import "core:testing"

@(private = "file")
said :: proc(login, text: string, badges: ..string) -> Chat_Message {
	m := Chat_Message {
		kind  = .Chat,
		login = login,
	}
	m.fragments = make([dynamic]Fragment, context.temp_allocator)
	append(&m.fragments, Fragment{kind = .Text, text = text})
	m.badges = make([dynamic]string, context.temp_allocator)
	append(&m.badges, ..badges)
	return m
}

@(test)
bots_and_commands_are_recognised :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bot := said("nightbot", "Follow on Twitter!")
	testing.expect(t, hidden_as_bot(&bot))
	command := said("someone", "!uptime")
	testing.expect(t, hidden_as_bot(&command))
	// Excitement, not a command.
	for text in ([]string{"! wow", "!!!", "hi!", "!"}) {
		m := said("someone", text)
		testing.expect(t, !hidden_as_bot(&m))
	}
	system := Chat_Message{kind = .System}
	testing.expect(t, !hidden_as_bot(&system))
}

@(test)
the_streamer_and_moderators_are_marked_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	streamer := said("lirik", "hi", "broadcaster/1", "subscriber/0")
	color, ok := staff_background(&streamer)
	testing.expect(t, ok)
	testing.expect_value(t, color, CHAT_STREAMER_BACKGROUND)
	mod := said("amod", "hi", "moderator/1")
	color, ok = staff_background(&mod)
	testing.expect_value(t, color, CHAT_MODERATOR_BACKGROUND)
	viewer := said("viewer", "hi", "subscriber/12")
	_, ok = staff_background(&viewer)
	testing.expect(t, !ok)
}

@(test)
chat_times_read_as_a_clock :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Local time, so only its shape: "14:05" or "2:05 PM".
	stamp := format_chat_time(1795115797938)
	testing.expect(t, strings.contains(stamp, ":"), stamp)
	testing.expect(t, len(stamp) == 5 || strings.has_suffix(stamp, " AM") || strings.has_suffix(stamp, " PM"), stamp)
}

@(test)
alternating_lines_keep_their_shade :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: Assets
	v: Chat_View
	defer chat_view_destroy(&v)
	add :: proc(v: ^Chat_View, a: ^Assets, login, text: string) {
		m := Chat_Message {
			kind  = .Chat,
			login = strings.clone(login),
		}
		append(&m.fragments, Fragment{kind = .Text, text = strings.clone(text)})
		chat_view_add(v, a, 1, 300, {m})
	}
	add(&v, &a, "one", "hi")
	add(&v, &a, "nightbot", "Follow on Twitter!")
	add(&v, &a, "two", "hello")
	first, bot, second := v.messages[0].line, v.messages[1].line, v.messages[2].line
	testing.expect_value(t, first, 0)
	testing.expect_value(t, bot, 1)
	testing.expect_value(t, second, 2)
	// Bots left out: the two people's messages still alternate.
	testing.expect_value(t, v.messages[2].line_unbotted, 1)
	// More arriving changes no one's number.
	add(&v, &a, "three", "hey")
	testing.expect_value(t, v.messages[0].line, 0)
	testing.expect_value(t, v.messages[2].line, 2)
	testing.expect_value(t, v.messages[3].line, 3)
}
