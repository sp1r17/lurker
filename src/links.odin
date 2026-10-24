package app

import "core:log"
import "core:strings"

Link_Kind :: enum {
	Channel,
	Video,
	Clip,
}

// What a command-line argument names: a channel (a login, or its twitch.tv page),
// a video (twitch.tv/videos/123, with ?t=1h2m3s) or a clip (clips.twitch.tv/Slug,
// or twitch.tv/<channel>/clip/Slug).
Twitch_Link :: struct {
	kind:  Link_Kind,
	// The login, video ID or clip slug. Points into the argument.
	id:    string,
	// Where to start a video, in seconds.
	start: int,
}

parse_twitch_link :: proc(arg: string) -> (link: Twitch_Link, ok: bool) {
	if valid_login(arg) {
		return {kind = .Channel, id = strings.to_lower(arg, context.temp_allocator)}, true
	}
	rest := arg
	rest = strings.trim_prefix(rest, "https://")
	rest = strings.trim_prefix(rest, "http://")
	query := ""
	if q := strings.index_byte(rest, '?'); q >= 0 {
		rest, query = rest[:q], rest[q + 1:]
	}
	rest = strings.trim_suffix(rest, "/")
	host, _, path := strings.partition(rest, "/")
	parts := strings.split(path, "/", context.temp_allocator)
	switch host {
	case "clips.twitch.tv":
		if len(parts) == 1 && parts[0] != "" {
			return {kind = .Clip, id = parts[0]}, true
		}
	case "twitch.tv", "www.twitch.tv", "m.twitch.tv":
		switch {
		case len(parts) == 2 && parts[0] == "videos" && is_number(parts[1]):
			return {kind = .Video, id = parts[1], start = link_start(query)}, true
		case len(parts) == 3 && parts[1] == "clip" && parts[2] != "":
			return {kind = .Clip, id = parts[2]}, true
		case len(parts) == 1 && valid_login(parts[0]):
			return {kind = .Channel, id = strings.to_lower(parts[0], context.temp_allocator)}, true
		}
	}
	return {}, false
}

@(private = "file")
is_number :: proc(s: string) -> bool {
	return s != "" && strings.trim_left(s, "0123456789") == ""
}

// The start time in a video link's query ("t=1h2m3s", "t=90s" or "t=90"), in
// seconds; 0 without one.
@(private = "file")
link_start :: proc(query: string) -> int {
	q := query
	for param in strings.split_iterator(&q, "&") {
		key, _, value := strings.partition(param, "=")
		if key != "t" {
			continue
		}
		total, n := 0, 0
		for c in value {
			switch c {
			case '0' ..= '9':
				n = n * 10 + int(c - '0')
			case 'h':
				total, n = total + n * 3600, 0
			case 'm':
				total, n = total + n * 60, 0
			case 's':
				total, n = total + n, 0
			case:
				return 0
			}
		}
		return total + n
	}
	return 0
}

// Looks up a video or clip from a link, to play it.
Link_Job :: struct {
	client_id: string,
	// A copy, empty when signed out.
	auth:      Auth,
	kind:      Link_Kind,
	id:        string,
	start:     int,
	ok:        bool,
	// Owned, if found.
	vod:       Vod,
}

destroy_link_job :: proc(p: ^Link_Job) {
	delete(p.client_id)
	destroy_auth(p.auth)
	delete(p.id)
	destroy_vod(p.vod)
}

// Opens a video or clip link: looked up first, then played.
open_link :: proc(app: ^App, link: Twitch_Link) {
	jobs_add(
		&app.assets.jobs,
		run_link_job,
		Link_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth) if app.signed_in else {},
			kind = link.kind,
			id = strings.clone(link.id),
			start = link.start,
		},
	)
}

@(private = "file")
run_link_job :: proc(job: ^Job) {
	p := &job.payload.(Link_Job)
	vod: Vod
	found: bool
	err: Twitch_Error
	#partial switch p.kind {
	case .Video:
		vod, found, err = get_video(p.client_id, p.auth.access_token, p.id)
	case .Clip:
		vod, found, err = get_clip(p.client_id, p.auth.access_token, p.id)
	}
	if err == .None && found {
		p.ok = true
		p.vod = clone_vod(vod)
	}
}

finish_link_job :: proc(app: ^App, p: ^Link_Job) {
	if !p.ok {
		log.errorf("can't find %v %s", p.kind, p.id)
		return
	}
	// A link's time is where to start; without one, where the user left off.
	watch_start_vod(app, p.vod, f64(p.start) if p.start > 0 else -1)
}
