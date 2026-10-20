package app

import "core:hash"
import "core:strconv"
import "core:strings"

// One IRC line, with Twitch's IRCv3 tags. All strings point into the line.
Irc_Message :: struct {
	tags:    string,
	prefix:  string,
	command: string,
	params:  []string,
}

// Splits an IRC line into tags, prefix, command and params. The trailing param (after
// " :") is the last one. Params are allocated with the temp allocator.
parse_irc :: proc(line: string) -> (msg: Irc_Message, ok: bool) {
	rest := strings.trim_right(line, "\r\n")
	if strings.has_prefix(rest, "@") {
		end := strings.index_byte(rest, ' ')
		if end < 0 {
			return {}, false
		}
		msg.tags = rest[1:end]
		rest = strings.trim_left(rest[end:], " ")
	}
	if strings.has_prefix(rest, ":") {
		end := strings.index_byte(rest, ' ')
		if end < 0 {
			return {}, false
		}
		msg.prefix = rest[1:end]
		rest = strings.trim_left(rest[end:], " ")
	}

	params := make([dynamic]string, context.temp_allocator)
	for rest != "" {
		if strings.has_prefix(rest, ":") {
			append(&params, rest[1:])
			break
		}
		end := strings.index_byte(rest, ' ')
		if end < 0 {
			append(&params, rest)
			break
		}
		append(&params, rest[:end])
		rest = strings.trim_left(rest[end:], " ")
	}
	if len(params) == 0 {
		return {}, false
	}
	msg.command = params[0]
	msg.params = params[1:]
	return msg, true
}

// The last param, which is the message text for PRIVMSG, NOTICE and USERNOTICE.
irc_trailing :: proc(msg: Irc_Message) -> string {
	return msg.params[len(msg.params) - 1] if len(msg.params) > 0 else ""
}

// Looks up a tag's value, unescaped (IRCv3 escapes ; space \ CR LF). The value is
// allocated with the temp allocator.
irc_tag :: proc(msg: Irc_Message, key: string) -> (value: string, found: bool) {
	tags := msg.tags
	for tag in strings.split_iterator(&tags, ";") {
		k, _, v := strings.partition(tag, "=")
		if k == key {
			return unescape_tag(v), true
		}
	}
	return "", false
}

@(private = "file")
unescape_tag :: proc(value: string) -> string {
	if strings.index_byte(value, '\\') < 0 {
		return value
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(value); i += 1 {
		if value[i] != '\\' || i + 1 == len(value) {
			strings.write_byte(&sb, value[i])
			continue
		}
		i += 1
		switch value[i] {
		case ':':
			strings.write_byte(&sb, ';')
		case 's':
			strings.write_byte(&sb, ' ')
		case 'r':
			strings.write_byte(&sb, '\r')
		case 'n':
			strings.write_byte(&sb, '\n')
		case:
			strings.write_byte(&sb, value[i])
		}
	}
	return strings.to_string(sb)
}

// The nick in a "nick!user@host" prefix.
irc_nick :: proc(msg: Irc_Message) -> string {
	nick, _, _ := strings.partition(msg.prefix, "!")
	return nick
}

Color :: [4]u8

Chat_Message_Kind :: enum {
	Chat,
	// /me messages, drawn in the sender's colour.
	Action,
	// Notices from Twitch (subs, raids, errors) and from the app (connection state).
	System,
}

// A message for the chat view. Strings are owned; free with destroy_chat_message.
Chat_Message :: struct {
	kind:  Chat_Message_Kind,
	name:  string,
	color: Color,
	text:  string,
}

destroy_chat_message :: proc(m: Chat_Message) {
	delete(m.name)
	delete(m.text)
}

system_message :: proc(text: string) -> Chat_Message {
	return {kind = .System, text = strings.clone(text)}
}

// Builds a chat message from a PRIVMSG, or the user's part of a USERNOTICE.
privmsg_to_chat :: proc(msg: Irc_Message) -> Chat_Message {
	// USERNOTICEs come from tmi.twitch.tv, so the sender is only in the login tag.
	login, has_login := irc_tag(msg, "login")
	if !has_login {
		login = irc_nick(msg)
	}
	name, has_name := irc_tag(msg, "display-name")
	// Some display names are in scripts that don't match the login (e.g. Korean);
	// Chatterino shows both then. Plain differences in case show just the display name.
	if !has_name || name == "" {
		name = login
	} else if strings.to_lower(name, context.temp_allocator) != login {
		name = strings.concatenate({name, " (", login, ")"}, context.temp_allocator)
	}

	text := irc_trailing(msg)
	kind := Chat_Message_Kind.Chat
	if strings.has_prefix(text, "\x01ACTION ") {
		kind = .Action
		text = strings.trim_suffix(text[len("\x01ACTION "):], "\x01")
	}

	tag_color, _ := irc_tag(msg, "color")
	color, color_ok := parse_hex_color(tag_color)
	if !color_ok {
		color = default_name_color(login)
	}
	return {kind = kind, name = strings.clone(name), color = readable_on_dark(color), text = strings.clone(text)}
}

parse_hex_color :: proc(s: string) -> (color: Color, ok: bool) {
	if len(s) != 7 || s[0] != '#' {
		return {}, false
	}
	rgb := strconv.parse_u64_of_base(s[1:], 16) or_return
	return {u8(rgb >> 16), u8(rgb >> 8), u8(rgb), 255}, true
}

// Twitch's palette for users who never picked a colour. Twitch picks one per user on
// its side; a hash of the login keeps each user's colour stable here.
@(rodata)
DEFAULT_NAME_COLORS := [?]Color {
	{0xFF, 0x00, 0x00, 255}, // Red
	{0x00, 0x00, 0xFF, 255}, // Blue
	{0x00, 0x80, 0x00, 255}, // Green
	{0xB2, 0x22, 0x22, 255}, // FireBrick
	{0xFF, 0x7F, 0x50, 255}, // Coral
	{0x9A, 0xCD, 0x32, 255}, // YellowGreen
	{0xFF, 0x45, 0x00, 255}, // OrangeRed
	{0x2E, 0x8B, 0x57, 255}, // SeaGreen
	{0xDA, 0xA5, 0x20, 255}, // GoldenRod
	{0xD2, 0x69, 0x1E, 255}, // Chocolate
	{0x5F, 0x9E, 0xA0, 255}, // CadetBlue
	{0x1E, 0x90, 0xFF, 255}, // DodgerBlue
	{0xFF, 0x69, 0xB4, 255}, // HotPink
	{0x8A, 0x2B, 0xE2, 255}, // BlueViolet
	{0x00, 0xFF, 0x7F, 255}, // SpringGreen
}

default_name_color :: proc(login: string) -> Color {
	return DEFAULT_NAME_COLORS[hash.fnv32a(transmute([]byte)login) % len(DEFAULT_NAME_COLORS)]
}

// Lightens colours too dark to read on the chat's dark background, as Chatterino
// does, by mixing them with white until they reach a minimum brightness.
MIN_NAME_LUMA :: 120

readable_on_dark :: proc(color: Color) -> Color {
	luma := 0.299 * f32(color.r) + 0.587 * f32(color.g) + 0.114 * f32(color.b)
	if luma >= MIN_NAME_LUMA {
		return color
	}
	t := (MIN_NAME_LUMA - luma) / (255 - luma)
	mix :: proc(c: u8, t: f32) -> u8 {
		return u8(f32(c) + (255 - f32(c)) * t + 0.5)
	}
	return {mix(color.r, t), mix(color.g, t), mix(color.b, t), color.a}
}
