package app

import "core:fmt"
import "core:slice"
import "core:strings"

CHAT_COMMANDS_HELP :: "Commands: /me, /highlight, /unhighlight, /highlights, /ignore, /unignore, /ignores"

// Runs a command typed in the chat box, other than /me (which is sent). Returns
// false if `text` isn't one.
pane_command :: proc(app: ^App, p: ^Chat_Pane, text: string) -> bool {
	name, _, arg := strings.partition(text, " ")
	arg = strings.trim_space(arg)
	rules := &app.layout.chat
	switch strings.to_lower(name, context.temp_allocator) {
	case "/highlight":
		phrase := strings.to_lower(arg, context.temp_allocator)
		if phrase == "" {
			pane_notice(app, p, "Highlight messages with a word or phrase: /highlight phrase")
			return true
		}
		rule_add(&rules.highlights, phrase)
		layout_save(&app.layout)
		pane_notice(app, p, fmt.tprintf("Messages with \"%s\" are highlighted now.", phrase))
	case "/unhighlight":
		phrase := strings.to_lower(arg, context.temp_allocator)
		if !rule_remove(&rules.highlights, phrase) {
			pane_notice(app, p, fmt.tprintf("\"%s\" isn't highlighted. /highlights lists what is.", phrase))
			return true
		}
		layout_save(&app.layout)
		pane_notice(app, p, fmt.tprintf("\"%s\" isn't highlighted any more.", phrase))
	case "/highlights":
		if len(rules.highlights) == 0 {
			pane_notice(app, p, "Nothing is highlighted but mentions of you. Add a phrase with /highlight phrase")
		} else {
			pane_notice(app, p, fmt.tprintf("Highlighted: %s", strings.join(rules.highlights[:], ", ", context.temp_allocator)))
		}
	case "/ignore":
		login := strings.to_lower(strings.trim_left(arg, "@"), context.temp_allocator)
		if !valid_login(login) {
			pane_notice(app, p, "Hide someone's messages: /ignore name")
			return true
		}
		chat_ignore(app, login)
		pane_notice(app, p, fmt.tprintf("Hiding messages from %s. /unignore %s shows them again.", login, login))
	case "/unignore":
		login := strings.to_lower(strings.trim_left(arg, "@"), context.temp_allocator)
		if !chat_unignore(app, login) {
			pane_notice(app, p, fmt.tprintf("%s isn't ignored. /ignores lists who is.", login))
			return true
		}
		pane_notice(app, p, fmt.tprintf("Showing messages from %s again.", login))
	case "/ignores":
		if len(rules.ignored) == 0 {
			pane_notice(app, p, "No one is ignored. Hide someone's messages with /ignore name")
		} else {
			pane_notice(app, p, fmt.tprintf("Ignored: %s", strings.join(rules.ignored[:], ", ", context.temp_allocator)))
		}
	case:
		return false
	}
	return true
}

// Hides `login`'s messages in every chat, from now on and those showing.
chat_ignore :: proc(app: ^App, login: string) {
	rule_add(&app.layout.chat.ignored, login)
	layout_save(&app.layout)
	for p in app.watch.panes {
		chat_view_remove_user(&p.view, login)
	}
}

// Shows `login`'s new messages again. False if they weren't ignored.
chat_unignore :: proc(app: ^App, login: string) -> bool {
	if !rule_remove(&app.layout.chat.ignored, login) {
		return false
	}
	layout_save(&app.layout)
	return true
}

chat_ignored :: proc(app: ^App, login: string) -> bool {
	return slice.contains(app.layout.chat.ignored[:], login)
}

// Adds a copy of `s` to `list`, unless it's empty or there already.
rule_add :: proc(list: ^[dynamic]string, s: string) {
	if s != "" && !slice.contains(list[:], s) {
		append(list, strings.clone(s))
	}
}

// Removes `s` from `list`. False if it wasn't there.
rule_remove :: proc(list: ^[dynamic]string, s: string) -> bool {
	i, found := slice.linear_search(list[:], s)
	if !found {
		return false
	}
	delete(list[i])
	ordered_remove(list, i)
	return true
}
