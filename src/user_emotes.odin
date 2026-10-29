package app

import "core:fmt"
import "core:strings"

// A Twitch emote the signed-in user can send. Strings are owned.
User_Emote :: struct {
	emote: Emote,
	// The channel it's from ("" for Twitch's own), and whether it only works in
	// that channel's chat (follower emotes).
	owner:         string,
	follower_only: bool,
	// Where it's from, for the emote picker: "moonmoon", "Twitch".
	label:         string,
}

// The user's emotes by name.
User_Emotes :: map[string]User_Emote

user_emotes_destroy :: proc(emotes: ^User_Emotes) {
	user_emotes_clear(emotes)
	delete(emotes^)
}

user_emotes_clear :: proc(emotes: ^User_Emotes) {
	for name, e in emotes {
		delete(name)
		destroy_user_emote(e)
	}
	clear(emotes)
}

@(private = "file")
destroy_user_emote :: proc(e: User_Emote) {
	delete(e.emote.url_1x)
	delete(e.emote.url_2x)
	delete(e.owner)
	delete(e.label)
}

// Whether `e` can be sent in `channel`'s chat.
user_emote_usable :: proc(e: User_Emote, channel: string) -> bool {
	return !e.follower_only || e.owner == channel
}

User_Emotes_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	check:     Auth_Check,
	ok:        bool,
	// Owned, moved into Assets.user_emotes when the job finishes.
	emotes:    User_Emotes,
}

destroy_user_emotes_job :: proc(p: ^User_Emotes_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	user_emotes_destroy(&p.emotes)
}

// Loads the signed-in user's emotes, for the emote picker, Tab completion and
// showing their own messages.
user_emotes_request :: proc(app: ^App) {
	if !app.signed_in {
		return
	}
	jobs_add(
		&app.assets.jobs,
		run_user_emotes_job,
		User_Emotes_Job{client_id = strings.clone(app.client_id), auth = clone_auth(app.auth)},
	)
}

@(private = "file")
run_user_emotes_job :: proc(job: ^Job) {
	p := &job.payload.(User_Emotes_Job)
	p.check = .Valid
	emotes, err := get_user_emotes(p.client_id, p.auth.access_token)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		emotes, err = get_user_emotes(p.client_id, p.auth.access_token)
	}
	if err != .None {
		return
	}
	p.ok = true
	for e in emotes {
		if e.token in p.emotes {
			continue
		}
		label := "Twitch"
		switch {
		case e.type == "FOLLOWER":
			label = fmt.tprintf("%s follower", e.owner)
		case e.owner != "" && e.owner != "twitch":
			label = e.owner
		}
		p.emotes[strings.clone(e.token)] = User_Emote {
			emote = {url_1x = fmt.aprintf(TWITCH_EMOTE_URL, e.id, "1.0"), url_2x = fmt.aprintf(TWITCH_EMOTE_URL, e.id, "2.0")},
			owner = strings.clone(e.owner),
			follower_only = e.type == "FOLLOWER",
			label = strings.clone(label),
		}
	}
}

finish_user_emotes_job :: proc(app: ^App, p: ^User_Emotes_Job) {
	apply_auth_check(app, p.check, p.auth)
	// Signed out meanwhile: they're someone else's now.
	if !p.ok || !app.signed_in {
		return
	}
	user_emotes_destroy(&app.assets.user_emotes)
	app.assets.user_emotes, p.emotes = p.emotes, {}
	app.assets.user_emotes_generation += 1
}
