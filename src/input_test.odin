package app

import "core:strings"
import "core:fmt"
import "core:testing"

@(test)
input_edits_by_character_and_word :: proc(t: ^testing.T) {
	ti: Text_Input
	defer input_destroy(&ti)
	input_insert(&ti, "héllo world")
	input_delete(&ti, .Word)
	testing.expect_value(t, input_text(&ti), "héllo ")
	input_move(&ti, .Char, forward = false)
	input_move(&ti, .Char, forward = false)
	input_delete(&ti, .Char)
	// "é" is two bytes; one Backspace removes it whole.
	input_move(&ti, .Line, forward = false)
	input_move(&ti, .Char, forward = true)
	input_move(&ti, .Char, forward = true)
	input_delete(&ti, .Char)
	testing.expect_value(t, input_text(&ti), "hlo ")
	input_move(&ti, .Line, forward = true)
	input_insert(&ti, "there")
	input_move(&ti, .Line, forward = false)
	input_delete(&ti, .Word, forward = true)
	testing.expect_value(t, input_text(&ti), " there")
}

@(test)
input_stops_at_twitch_limit :: proc(t: ^testing.T) {
	ti: Text_Input
	defer input_destroy(&ti)
	input_insert(&ti, strings.repeat("a", MAX_MESSAGE_BYTES - 1, context.temp_allocator))
	// Two bytes don't fit in one; the character isn't split.
	input_insert(&ti, "é")
	testing.expect_value(t, len(ti.text), MAX_MESSAGE_BYTES - 1)
	free_all(context.temp_allocator)
}

@(test)
tab_completes_and_cycles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ti: Text_Input
	defer input_destroy(&ti)
	emotes := []string{"catJAM", "Catge", "KEKW"}
	users := []string{"CatLover", "lirik"}
	input_insert(&ti, "so cat")
	input_complete(&ti, emotes, users)
	testing.expect_value(t, input_text(&ti), "so Catge ")
	input_complete(&ti, emotes, users)
	testing.expect_value(t, input_text(&ti), "so catJAM ")
	input_complete(&ti, emotes, users)
	testing.expect_value(t, input_text(&ti), "so CatLover ")
	input_complete(&ti, emotes, users, backwards = true)
	testing.expect_value(t, input_text(&ti), "so catJAM ")

	input_clear(&ti)
	input_insert(&ti, "@li")
	input_complete(&ti, emotes, users)
	testing.expect_value(t, input_text(&ti), "@lirik ")
}

@(test)
own_messages_use_userstate :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m := own_message("me", "chan", "badges=subscriber/12;color=#00FF00;display-name=Me", "\x01ACTION waves\x01")
	defer destroy_chat_message(m)
	testing.expect_value(t, m.kind, Chat_Message_Kind.Action)
	testing.expect_value(t, m.name, "Me")
	testing.expect_value(t, m.color, Color{0, 255, 0, 255})
	testing.expect_value(t, m.badges[0], "subscriber/12")
	testing.expect_value(t, m.fragments[0].text, "waves")
}

@(test)
selection_replaces_and_deletes :: proc(t: ^testing.T) {
	ti: Text_Input
	defer input_destroy(&ti)
	input_insert(&ti, "hello world")
	input_select_all(&ti)
	testing.expect_value(t, input_selected_text(&ti), "hello world")
	// Typing replaces the selection.
	input_insert(&ti, "bye")
	testing.expect_value(t, input_text(&ti), "bye")

	input_insert(&ti, " now")
	// Shift+Ctrl+Left selects the last word; Backspace removes just it.
	input_move(&ti, .Word, forward = false, extend = true)
	testing.expect_value(t, input_selected_text(&ti), "now")
	input_delete(&ti, .Char)
	testing.expect_value(t, input_text(&ti), "bye ")

	// Left without Shift collapses a selection to its start.
	input_select_all(&ti)
	input_move(&ti, .Char, forward = false)
	testing.expect_value(t, ti.cursor, 0)
	testing.expect_value(t, input_selected_text(&ti), "")
}

@(test)
own_replies_show_what_they_answer :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	echo := fmt.tprintf(
		"color=#00FF00;display-name=Me;reply-parent-display-name=%s;reply-parent-user-login=foo;reply-parent-msg-body=%s",
		escape_tag("Foo"),
		escape_tag(`is it; live? \o/`),
	)
	m := own_message("me", "chan", echo, "@Foo yes")
	defer destroy_chat_message(m)
	testing.expect_value(t, m.reply, `Replying to @Foo: is it; live? \o/`)
	testing.expect_value(t, m.fragments[0].text, "yes")
}
