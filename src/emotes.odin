package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

// Third-party emote sets, in lookup order: the channel's own emotes win over global
// ones, and between providers 7TV, then BTTV, then FFZ, as in Chatterino.
Emote_Source :: enum {
	Channel_7TV,
	Channel_BTTV,
	Channel_FFZ,
	Global_7TV,
	Global_BTTV,
	Global_FFZ,
}

Emote :: struct {
	url_1x:     string,
	url_2x:     string,
	// 7TV's zero-width emotes draw over the emote before them.
	zero_width: bool,
}

Badge :: struct {
	url_1x: string,
	url_2x: string,
}

// Third-party emotes by name, and Twitch badges by "set/version" (e.g.
// "subscriber/12"). Strings are owned.
Emotes :: struct {
	sets:   [Emote_Source]map[string]Emote,
	badges: map[string]Badge,
}

emotes_destroy :: proc(e: ^Emotes) {
	for &set in e.sets {
		for name, emote in set {
			delete(name)
			delete(emote.url_1x)
			delete(emote.url_2x)
		}
		delete(set)
	}
	for key, badge in e.badges {
		delete(key)
		delete(badge.url_1x)
		delete(badge.url_2x)
	}
	delete(e.badges)
}

emote_lookup :: proc(e: ^Emotes, name: string) -> (emote: Emote, found: bool) {
	for &set in e.sets {
		if emote, found = set[name]; found {
			return
		}
	}
	return
}

emote_set_url :: proc(source: Emote_Source, room_id: string) -> string {
	switch source {
	case .Global_7TV:
		return "https://7tv.io/v3/emote-sets/global"
	case .Global_BTTV:
		return "https://api.betterttv.net/3/cached/emotes/global"
	case .Global_FFZ:
		return "https://api.betterttv.net/3/cached/frankerfacez/emotes/global"
	case .Channel_7TV:
		return fmt.tprintf("https://7tv.io/v3/users/twitch/%s", room_id)
	case .Channel_BTTV:
		return fmt.tprintf("https://api.betterttv.net/3/cached/users/twitch/%s", room_id)
	case .Channel_FFZ:
		return fmt.tprintf("https://api.betterttv.net/3/cached/frankerfacez/users/twitch/%s", room_id)
	}
	return ""
}

Named_Emote :: struct {
	name:  string,
	emote: Emote,
}

Emote_Set_Job :: struct {
	source: Emote_Source,
	url:    string,
	// Owned strings, moved into Emotes when the job finishes.
	emotes: [dynamic]Named_Emote,
}

destroy_emote_set_job :: proc(p: ^Emote_Set_Job) {
	for e in p.emotes {
		delete(e.name)
		delete(e.emote.url_1x)
		delete(e.emote.url_2x)
	}
	delete(p.emotes)
	delete(p.url)
}

emotes_request_set :: proc(jobs: ^Jobs, source: Emote_Source, room_id := "") {
	jobs_add(jobs, run_emote_set_job, Emote_Set_Job{source = source, url = strings.clone(emote_set_url(source, room_id))})
}

@(private = "file")
run_emote_set_job :: proc(job: ^Job) {
	p := &job.payload.(Emote_Set_Job)
	res, ok := http_request(p.url, allocator = context.temp_allocator)
	if !ok {
		return
	}
	// A channel that doesn't use a provider is a 404 there.
	if res.status == 404 {
		return
	}
	if res.status != 200 {
		log.warnf("%v emotes: HTTP %d", p.source, res.status)
		return
	}
	if !parse_emote_set(p.source, res.body, &p.emotes) {
		log.warnf("%v emotes: unexpected response", p.source)
	}
}

// Parses a provider's response into owned emotes.
parse_emote_set :: proc(source: Emote_Source, body: []byte, out: ^[dynamic]Named_Emote) -> bool {
	Seventv_Set :: struct {
		emotes: []struct {
			name:  string,
			// Bit 0: zero-width.
			flags: int,
			data:  struct {
				host: struct {
					url: string,
				},
			},
		},
	}
	Bttv_Emote :: struct {
		id:   string,
		code: string,
	}
	Ffz_Emote :: struct {
		code:   string,
		images: struct {
			x1: string `json:"1x"`,
			x2: string `json:"2x"`,
		},
	}

	switch source {
	case .Global_7TV, .Channel_7TV:
		set: Seventv_Set
		if source == .Global_7TV {
			if json.unmarshal(body, &set, allocator = context.temp_allocator) != nil {
				return false
			}
		} else {
			user: struct {
				emote_set: Seventv_Set,
			}
			if json.unmarshal(body, &user, allocator = context.temp_allocator) != nil {
				return false
			}
			set = user.emote_set
		}
		for e in set.emotes {
			// host.url is protocol-relative: "//cdn.7tv.app/emote/<id>".
			append(
				out,
				Named_Emote {
					strings.clone(e.name),
					{
						url_1x = strings.concatenate({"https:", e.data.host.url, "/1x.webp"}),
						url_2x = strings.concatenate({"https:", e.data.host.url, "/2x.webp"}),
						zero_width = e.flags & 1 != 0,
					},
				},
			)
		}
	case .Global_BTTV, .Channel_BTTV:
		list: []Bttv_Emote
		if source == .Global_BTTV {
			if json.unmarshal(body, &list, allocator = context.temp_allocator) != nil {
				return false
			}
		} else {
			user: struct {
				channelEmotes: []Bttv_Emote,
				sharedEmotes:  []Bttv_Emote,
			}
			if json.unmarshal(body, &user, allocator = context.temp_allocator) != nil {
				return false
			}
			all := make([dynamic]Bttv_Emote, context.temp_allocator)
			append(&all, ..user.channelEmotes)
			append(&all, ..user.sharedEmotes)
			list = all[:]
		}
		for e in list {
			append(
				out,
				Named_Emote {
					strings.clone(e.code),
					{
						url_1x = fmt.aprintf("https://cdn.betterttv.net/emote/%s/1x", e.id),
						url_2x = fmt.aprintf("https://cdn.betterttv.net/emote/%s/2x", e.id),
					},
				},
			)
		}
	case .Global_FFZ, .Channel_FFZ:
		list: []Ffz_Emote
		if json.unmarshal(body, &list, allocator = context.temp_allocator) != nil {
			return false
		}
		for e in list {
			if e.images.x1 == "" {
				continue
			}
			append(
				out,
				Named_Emote{strings.clone(e.code), {url_1x = strings.clone(e.images.x1), url_2x = strings.clone(e.images.x2)}},
			)
		}
	}
	return true
}

// On the main thread: moves the job's emotes into the store.
finish_emote_set_job :: proc(e: ^Emotes, p: ^Emote_Set_Job) {
	set := &e.sets[p.source]
	for named in p.emotes {
		// A set can be reloaded (after a reconnect); the new copy replaces the old.
		if named.name in set {
			old_name, old := delete_key(set, named.name)
			delete(old_name)
			delete(old.url_1x)
			delete(old.url_2x)
		}
		set[named.name] = named.emote
	}
	if len(p.emotes) > 0 {
		log.infof("loaded %d %v emotes", len(p.emotes), p.source)
	}
	clear(&p.emotes)
}

Badges_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	room_id:   string,
	check:     Auth_Check,
	badges:    [dynamic]Named_Badge,
}

Named_Badge :: struct {
	key:   string,
	badge: Badge,
}

destroy_badges_job :: proc(p: ^Badges_Job) {
	for b in p.badges {
		delete(b.key)
		delete(b.badge.url_1x)
		delete(b.badge.url_2x)
	}
	delete(p.badges)
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.room_id)
}

emotes_request_badges :: proc(jobs: ^Jobs, client_id: string, auth: Auth, room_id: string) {
	jobs_add(
		jobs,
		run_badges_job,
		Badges_Job{client_id = strings.clone(client_id), auth = clone_auth(auth), room_id = strings.clone(room_id)},
	)
}

// Twitch's badge list needs a token, so this checks (and if needed refreshes) the
// saved sign-in first.
@(private = "file")
run_badges_job :: proc(job: ^Job) {
	p := &job.payload.(Badges_Job)
	p.check = check_auth(p.client_id, &p.auth)
	if p.check == .Signed_Out || p.check == .Unreachable {
		return
	}
	paths := []string{"/chat/badges/global", fmt.tprintf("/chat/badges?broadcaster_id=%s", p.room_id)}
	for path in paths {
		body, err := helix_get(p.client_id, p.auth.access_token, path)
		if err == .Unauthorized {
			p.check = refresh_auth(p.client_id, &p.auth)
			if p.check != .Refreshed {
				return
			}
			body, err = helix_get(p.client_id, p.auth.access_token, path)
		}
		if err != .None || !parse_badges(body, &p.badges) {
			log.warnf("badges %s: failed (%v)", path, err)
		}
	}
}

// Parses Helix's badge sets into owned "set/version" badges. Channel badges come
// after global ones, so they replace them (a channel's own subscriber badges).
parse_badges :: proc(body: []byte, out: ^[dynamic]Named_Badge) -> bool {
	Response :: struct {
		data: []struct {
			set_id:   string,
			versions: []struct {
				id:           string,
				image_url_1x: string,
				image_url_2x: string,
			},
		},
	}
	r: Response
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return false
	}
	for set in r.data {
		for v in set.versions {
			append(
				out,
				Named_Badge {
					fmt.aprintf("%s/%s", set.set_id, v.id),
					{strings.clone(v.image_url_1x), strings.clone(v.image_url_2x)},
				},
			)
		}
	}
	return true
}

// On the main thread: stores the badges. The caller handles p.check, saving a
// refreshed sign-in or dropping a rejected one.
finish_badges_job :: proc(e: ^Emotes, p: ^Badges_Job) {
	for named in p.badges {
		if old, found := e.badges[named.key]; found {
			delete(old.url_1x)
			delete(old.url_2x)
			e.badges[named.key] = named.badge
			delete(named.key)
		} else {
			e.badges[named.key] = named.badge
		}
	}
	if len(p.badges) > 0 {
		log.infof("loaded %d badges", len(p.badges))
	}
	clear(&p.badges)
}
