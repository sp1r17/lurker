package app

import "core:strings"

// The logins currently live. Keys are owned by the set.
Live_Set :: map[string]struct{}

Live_Changes :: struct {
	went_live:    []Stream,
	went_offline: []string,
}

// Replaces the set's contents with `streams` and reports what changed. The changes
// are allocated with the temp allocator.
update_live_set :: proc(live: ^Live_Set, streams: []Stream) -> Live_Changes {
	now := make(map[string]struct{}, len(streams), context.temp_allocator)
	went_live := make([dynamic]Stream, context.temp_allocator)
	for s in streams {
		now[s.user_login] = {}
		if s.user_login not_in live {
			append(&went_live, s)
			live[strings.clone(s.user_login)] = {}
		}
	}

	went_offline := make([dynamic]string, context.temp_allocator)
	for login in live {
		if login not_in now {
			append(&went_offline, strings.clone(login, context.temp_allocator))
		}
	}
	for login in went_offline {
		key, _ := delete_key(live, login)
		delete(key)
	}
	return {went_live = went_live[:], went_offline = went_offline[:]}
}

destroy_live_set :: proc(live: ^Live_Set) {
	for login in live {
		delete(login)
	}
	delete(live^)
}
