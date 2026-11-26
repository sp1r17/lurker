package app

import "core:fmt"
import "core:strings"

// Nicknames: the user's own name for someone, shown in chat in place of theirs.
// Only where messages show: mentions, replies and the user card keep the name
// Twitch has, so what's sent still reaches them.

// Both owned. `login` is lowercase.
Nickname :: struct {
	login:    string,
	nickname: string,
}

// The login and nickname typed as "name -> nickname", or "name nickname";
// ok false if either is missing or the login can't be one. Allocated with the
// temp allocator.
parse_nickname :: proc(typed: string) -> (login, nickname: string, ok: bool) {
	text := strings.trim_space(typed)
	name, rest: string
	if i := strings.index(text, "->"); i >= 0 {
		name, rest = text[:i], text[i + 2:]
	} else if space := strings.index_any(text, " \t"); space >= 0 {
		name, rest = text[:space], text[space:]
	} else {
		return "", "", false
	}
	login = strings.to_lower(strings.trim_left(strings.trim_space(name), "@"), context.temp_allocator)
	nickname = strings.trim_space(rest)
	return login, nickname, valid_login(login) && nickname != ""
}

// Gives `login` a nickname, in place of any they had.
nickname_set :: proc(list: ^[dynamic]Nickname, login, nickname: string) {
	for &n in list {
		if n.login == login {
			delete(n.nickname)
			n.nickname = strings.clone(nickname)
			return
		}
	}
	append(list, Nickname{strings.clone(login), strings.clone(nickname)})
}

nickname_remove :: proc(list: ^[dynamic]Nickname, i: int) {
	if i < 0 || i >= len(list) {
		return
	}
	delete(list[i].login)
	delete(list[i].nickname)
	ordered_remove(list, i)
}

nicknames_destroy :: proc(list: ^[dynamic]Nickname) {
	for n in list {
		delete(n.login)
		delete(n.nickname)
	}
	delete(list^)
}

// The name to show for `m`'s sender: their nickname, or the name they have.
shown_name :: proc(m: ^Chat_Message, rules: ^Chat_Rules) -> string {
	if rules != nil && m.kind != .System && m.login != "" {
		for n in rules.nicknames {
			if n.login == m.login {
				return n.nickname
			}
		}
	}
	return m.name
}

// "name -> nickname" for each, for the settings list. Allocated with the temp
// allocator.
nickname_entries :: proc(list: []Nickname) -> []string {
	entries := make([]string, len(list), context.temp_allocator)
	for n, i in list {
		entries[i] = fmt.tprintf("%s -> %s", n.login, n.nickname)
	}
	return entries
}

// Lays every chat's messages out again, after a nickname changed.
chat_nicknames_changed :: proc(app: ^App) {
	layout_save(&app.layout)
	for p in app.watch.panes {
		chat_view_refresh_badges(&p.view)
	}
}
