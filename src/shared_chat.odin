package app

import "core:encoding/json"
import "core:strings"

// Shared Chat: channels streaming together share one chat, and each message
// carries the channel it was sent in (source-room-id). Messages from another
// channel than the one whose chat this is show that channel's name before them,
// dimmed; names are looked up by ID once and kept.

// The channel a message was sent in, by ID, if that's another than the chat's
// own room; "" otherwise.
shared_source_room :: proc(msg: Irc_Message) -> string {
	source, has_source := irc_tag(msg, "source-room-id")
	room, _ := irc_tag(msg, "room-id")
	if !has_source || source == "" || source == room {
		return ""
	}
	return source
}

// Channels' names by ID, for Shared Chat, and those being looked up. All owned.
Room_Names :: struct {
	names:   map[string]string,
	pending: map[string]struct{},
	// Moves on as names arrive, so messages showing one are laid out again.
	version: int,
}

room_names_destroy :: proc(r: ^Room_Names) {
	for id, name in r.names {
		delete(id)
		delete(name)
	}
	delete(r.names)
	for id in r.pending {
		delete(id)
	}
	delete(r.pending)
}

// The name of channel `id`, if known; otherwise it's looked up (once), and the
// messages from it are laid out again when it's found.
room_name :: proc(a: ^Assets, id: string) -> (name: string, ok: bool) {
	r := &a.rooms
	if known, found := r.names[id]; found {
		return known, true
	}
	if id in r.pending || a.client_id == "" {
		return "", false
	}
	r.pending[strings.clone(id)] = {}
	jobs_add(&a.jobs, run_room_name_job, Room_Name_Job{client_id = strings.clone(a.client_id), id = strings.clone(id)})
	return "", false
}

Room_Name_Job :: struct {
	client_id, id: string,
	// The channel's display name; "" if it wasn't found. Owned.
	name:          string,
}

destroy_room_name_job :: proc(p: ^Room_Name_Job) {
	delete(p.client_id)
	delete(p.id)
	delete(p.name)
}

@(private = "file")
run_room_name_job :: proc(job: ^Job) {
	p := &job.payload.(Room_Name_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["id"] = p.id
	body, err := gql_post(p.client_id, "", "query($id: ID!) { user(id: $id) { login displayName } }", variables)
	if err != .None {
		return
	}
	r: struct {
		data: struct {
			user: Maybe(struct {
				login, displayName: string,
			}),
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return
	}
	if user, ok := r.data.user.?; ok {
		p.name = strings.clone(user.displayName if user.displayName != "" else user.login)
	}
}

finish_room_name_job :: proc(a: ^Assets, p: ^Room_Name_Job) {
	r := &a.rooms
	if p.id in r.pending {
		key, _ := delete_key(&r.pending, p.id)
		delete(key)
	}
	if p.name == "" || p.id in r.names {
		return
	}
	r.names[strings.clone(p.id)] = p.name
	p.name = ""
	r.version += 1
}
