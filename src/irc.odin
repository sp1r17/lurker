package app

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

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

Fragment_Kind :: enum {
	Text,
	Emote,
}

// A run of text, or one emote. Strings are owned by the message.
Fragment :: struct {
	kind:       Fragment_Kind,
	// The text, or the emote's name (shown if its image fails to load).
	text:       string,
	url_1x:     string,
	url_2x:     string,
	zero_width: bool,
}

// What a moderation message does to earlier messages.
Clear_Kind :: enum {
	None,
	// One message, by ID (CLEARMSG).
	Message,
	// Everything a user said (CLEARCHAT with a user: a timeout or ban).
	User,
	// The whole chat (CLEARCHAT without a user).
	All,
}

// A message for the chat view. Strings are owned; free with destroy_chat_message.
Chat_Message :: struct {
	kind:      Chat_Message_Kind,
	name:      string,
	color:     Color,
	// Twitch's message ID, and the sender's login and user ID; empty for system
	// messages and our own.
	id:        string,
	login:     string,
	user_id:   string,
	// Removed by a moderator: drawn faded.
	deleted:   bool,
	// Mentions the signed-in user.
	mention:   bool,
	// For moderation messages: what to clear when this arrives, and whose
	// (a message ID or a login).
	clear:     Clear_Kind,
	clear_target: string,
	// "set/version" badge keys, e.g. "subscriber/12".
	badges:    [dynamic]string,
	fragments: [dynamic]Fragment,
	// Cached by the chat view.
	layout:    Message_Layout,
}

destroy_chat_message :: proc(m: Chat_Message) {
	delete(m.name)
	delete(m.id)
	delete(m.login)
	delete(m.user_id)
	delete(m.clear_target)
	for b in m.badges {
		delete(b)
	}
	delete(m.badges)
	destroy_fragments(m.fragments[:])
	delete(m.fragments)
	delete(m.layout.items)
}

destroy_fragments :: proc(fragments: []Fragment) {
	for f in fragments {
		delete(f.text)
		delete(f.url_1x)
		delete(f.url_2x)
	}
}

system_message :: proc(text: string) -> Chat_Message {
	m := Chat_Message {
		kind = .System,
	}
	append(&m.fragments, Fragment{kind = .Text, text = strings.clone(text)})
	return m
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

	id, _ := irc_tag(msg, "id")
	user_id, _ := irc_tag(msg, "user-id")
	m := Chat_Message {
		kind    = kind,
		name    = strings.clone(name),
		color   = readable_on_dark(color),
		id      = strings.clone(id),
		login   = strings.clone(login),
		user_id = strings.clone(user_id),
	}
	badges, _ := irc_tag(msg, "badges")
	for badge in strings.split_iterator(&badges, ",") {
		if badge != "" {
			append(&m.badges, strings.clone(badge))
		}
	}
	emotes_tag, _ := irc_tag(msg, "emotes")
	twitch_emote_fragments(text, emotes_tag, &m.fragments)
	return m
}

// A CLEARCHAT or CLEARMSG as a message: the moderation to apply, and for timeouts
// and bans, a line saying so.
moderation_message :: proc(msg: Irc_Message) -> (m: Chat_Message, ok: bool) {
	switch msg.command {
	case "CLEARMSG":
		target, has_target := irc_tag(msg, "target-msg-id")
		if !has_target {
			return {}, false
		}
		return {kind = .System, clear = .Message, clear_target = strings.clone(target)}, true
	case "CLEARCHAT":
		if len(msg.params) < 2 {
			m = system_message("Chat was cleared by a moderator.")
			m.clear = .All
			return m, true
		}
		login := irc_trailing(msg)
		if seconds, has_duration := irc_tag(msg, "ban-duration"); has_duration {
			n, _ := strconv.parse_int(seconds, 10)
			m = system_message(fmt.tprintf("%s has been timed out for %s.", login, format_duration(n)))
		} else {
			m = system_message(fmt.tprintf("%s has been permanently banned.", login))
		}
		m.clear = .User
		m.clear_target = strings.clone(login)
		return m, true
	}
	return {}, false
}

// "45s", "10m", "1h 30m", "7d": how Chatterino words timeouts.
format_duration :: proc(seconds: int) -> string {
	switch {
	case seconds < 60:
		return fmt.tprintf("%ds", seconds)
	case seconds < 3600:
		return fmt.tprintf("%dm", seconds / 60)
	case seconds < 86400:
		if seconds % 3600 / 60 == 0 {
			return fmt.tprintf("%dh", seconds / 3600)
		}
		return fmt.tprintf("%dh %dm", seconds / 3600, seconds % 3600 / 60)
	case:
		return fmt.tprintf("%dd", seconds / 86400)
	}
}

// Whether the message's text mentions `login`, as a word ("@login", "login,").
mentions :: proc(m: ^Chat_Message, login: string) -> bool {
	if login == "" || m.kind == .System || m.login == login {
		return false
	}
	for f in m.fragments {
		if f.kind != .Text {
			continue
		}
		rest := f.text
		for word in strings.fields_iterator(&rest) {
			w := strings.trim_left(word, "@")
			w = strings.trim_right(w, ",.!?:;")
			if strings.equal_fold(w, login) {
				return true
			}
		}
	}
	return false
}

TWITCH_EMOTE_URL :: "https://static-cdn.jtvnw.net/emoticons/v2/%s/default/dark/%s"

// Splits `text` into text and emote fragments using the emotes tag, which looks like
// "25:0-4,12-16/1902:6-10": emote IDs with the inclusive character (not byte) ranges
// where they appear. Ranges that don't fit the text are ignored.
twitch_emote_fragments :: proc(text, emotes_tag: string, out: ^[dynamic]Fragment) {
	Placement :: struct {
		id:         string,
		start, end: int, // character indices, end exclusive
	}
	placements := make([dynamic]Placement, context.temp_allocator)
	rest := emotes_tag
	for entry in strings.split_iterator(&rest, "/") {
		id, _, ranges := strings.partition(entry, ":")
		for r in strings.split_iterator(&ranges, ",") {
			a, _, b := strings.partition(r, "-")
			start, ok_a := strconv.parse_int(a, 10)
			end, ok_b := strconv.parse_int(b, 10)
			if ok_a && ok_b && start <= end {
				append(&placements, Placement{id, start, end + 1})
			}
		}
	}
	slice.sort_by(placements[:], proc(x, y: Placement) -> bool {return x.start < y.start})

	// Character index -> byte offset, with one extra entry for the end.
	offsets := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< len(text) {
		if !utf8.rune_start(text[i]) {
			continue
		}
		append(&offsets, i)
	}
	append(&offsets, len(text))
	char_count := len(offsets) - 1

	byte_pos := 0
	char_pos := 0
	for p in placements {
		if p.start < char_pos || p.end > char_count {
			continue
		}
		if p.start > char_pos {
			append(out, Fragment{kind = .Text, text = strings.clone(text[byte_pos:offsets[p.start]])})
		}
		name := text[offsets[p.start]:offsets[p.end]]
		append(
			out,
			Fragment {
				kind = .Emote,
				text = strings.clone(name),
				url_1x = fmt.aprintf(TWITCH_EMOTE_URL, p.id, "1.0"),
				url_2x = fmt.aprintf(TWITCH_EMOTE_URL, p.id, "2.0"),
			},
		)
		byte_pos = offsets[p.end]
		char_pos = p.end
	}
	if byte_pos < len(text) {
		append(out, Fragment{kind = .Text, text = strings.clone(text[byte_pos:])})
	}
}

// Replaces words in the message's text fragments that name a third-party emote,
// the channel's (`channel`, may be nil) or global.
apply_third_party_emotes :: proc(m: ^Chat_Message, channel, global: ^Emotes) {
	if m.kind == .System {
		return
	}
	old := m.fragments
	m.fragments = make([dynamic]Fragment)
	pending := strings.builder_make(context.temp_allocator)
	flush :: proc(pending: ^strings.Builder, out: ^[dynamic]Fragment) {
		if strings.builder_len(pending^) > 0 {
			append(out, Fragment{kind = .Text, text = strings.clone(strings.to_string(pending^))})
			strings.builder_reset(pending)
		}
	}
	for f in old {
		if f.kind != .Text {
			append(&m.fragments, f)
			continue
		}
		rest := f.text
		for word in strings.fields_iterator(&rest) {
			if emote, found := emote_lookup(channel, global, word); found {
				flush(&pending, &m.fragments)
				append(
					&m.fragments,
					Fragment {
						kind = .Emote,
						text = strings.clone(word),
						url_1x = strings.clone(emote.url_1x),
						url_2x = strings.clone(emote.url_2x),
						zero_width = emote.zero_width,
					},
				)
			} else {
				if strings.builder_len(pending) > 0 {
					strings.write_byte(&pending, ' ')
				}
				strings.write_string(&pending, word)
			}
		}
		flush(&pending, &m.fragments)
		delete(f.text)
	}
	delete(old)
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
