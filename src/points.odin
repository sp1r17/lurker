package app

import "core:encoding/base64"
import "core:encoding/json"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"

// Channel points from watch time. Twitch credits watch time from "minute-watched"
// events that its own player sends. Lurker plays through streamlink, which sends
// none, so Lurker sends them: one for each minute a live stream actually plays,
// counted from mpv's position, so paused and buffering time doesn't count. The
// event and where it goes are Twitch's site internals, not a documented API: if
// they change, reporting stops and nothing else does.

POINTS_MINUTE_S :: 60
// How often the position is sampled while a live stream plays, and how far it may
// run ahead of the clock in one sample.
POINTS_TICK_MS :: 5_000
POINTS_CATCH_UP_S :: 2
// Where the events go, in the order tried, if twitch.tv's settings can't be read:
// they're what the settings give. Both are on some DNS blocklists (spade, here),
// so a report that can't get through tries the other.
POINTS_TRACK_URLS :: [?]string{"https://spade.twitch.tv/track", "https://beacon.twitch.tv/track"}

Points :: struct {
	// Seconds of playback not yet reported, and the position last seen (for the
	// stream started at `started_at`, Watch.started_at).
	watched:    f64,
	last_pos:   Maybe(f64),
	last_at:    int,
	started_at: int,
	// Where events go: looked up once (empty until then) and kept, with the one
	// that last worked first. Owned.
	urls:       [dynamic]string,
	pending:    bool,
	// Logged once, so a blocked address doesn't fill the log every minute.
	warned:     bool,
}

points_destroy :: proc(p: ^Points) {
	for u in p.urls {
		delete(u)
	}
	delete(p.urls)
}

// Adds up the playing time of the live stream being watched, and reports each
// minute. Returns ms until it's next due, for the main loop's wait.
points_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	p := &app.points
	if app.screen != .Watch || !app.signed_in || app.layout.points_off || w.playing_vod || w.status != .Playing || !w.has_info || w.info.id == "" {
		p.last_pos = nil
		return -1
	}
	now := app.assets.now_ms
	pos, playing := player_position(&app.player)
	if !playing {
		p.last_pos = nil
		return POINTS_TICK_MS
	}
	if p.started_at != w.started_at {
		// Another stream: what's left of the last one isn't reported for it.
		p.watched = 0
		p.last_pos = nil
	}
	if last, ok := p.last_pos.?; ok {
		// About the time that passed at most: streamlink cutting out an ad can
		// move the position on, and a restart moves it back. mpv reports the
		// position unevenly, so a sample can catch up on the last one.
		played := pos - last
		elapsed := f64(now - p.last_at) / 1000
		if played > 0 {
			p.watched += min(played, elapsed + POINTS_CATCH_UP_S)
		}
	}
	p.last_pos, p.last_at, p.started_at = pos, now, w.started_at
	if p.watched >= POINTS_MINUTE_S && !p.pending {
		p.watched -= POINTS_MINUTE_S
		points_report(app)
	}
	return POINTS_TICK_MS
}

@(private = "file")
points_report :: proc(app: ^App) {
	w := &app.watch
	p := &app.points
	user_id, ok := strconv.parse_i64(app.auth.user_id)
	if !ok {
		return
	}
	urls := make([dynamic]string, 0, len(p.urls))
	for u in p.urls {
		append(&urls, strings.clone(u))
	}
	p.pending = true
	jobs_add(
		&app.assets.jobs,
		run_points_job,
		Points_Job {
			urls = urls,
			login = strings.clone(w.channel),
			channel_id = strings.clone(w.info.user_id),
			broadcast_id = strings.clone(w.info.id),
			user_id = user_id,
		},
	)
}

Points_Job :: struct {
	// The addresses to try (empty to look them up), then in the order to try
	// next time: the one that worked first. Owned.
	urls:         [dynamic]string,
	login:        string,
	channel_id:   string,
	broadcast_id: string,
	user_id:      i64,
	sent:         bool,
	// The status of the last address tried, 0 if it couldn't be reached.
	status:       int,
}

destroy_points_job :: proc(p: ^Points_Job) {
	for u in p.urls {
		delete(u)
	}
	delete(p.urls)
	delete(p.login)
	delete(p.channel_id)
	delete(p.broadcast_id)
}

@(private = "file")
run_points_job :: proc(job: ^Job) {
	p := &job.payload.(Points_Job)
	if len(p.urls) == 0 {
		points_lookup_urls(p.login, &p.urls)
	}
	event := struct {
		event:      string,
		properties: struct {
			channel_id:   string,
			broadcast_id: string,
			player:       string,
			user_id:      i64,
			live:         bool,
			channel:      string,
		},
	} {
		event = "minute-watched",
		properties = {p.channel_id, p.broadcast_id, "site", p.user_id, true, p.login},
	}
	data, err := json.marshal(event, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	encoded := base64.encode(data, allocator = context.temp_allocator)
	body := strings.concatenate({"data=", net.percent_encode(encoded, context.temp_allocator)}, context.temp_allocator)
	headers := []string{"Content-Type: application/x-www-form-urlencoded"}
	for url, i in p.urls {
		res, reached := http_request(url, headers, post_body = body, allocator = context.temp_allocator)
		p.status = res.status if reached else 0
		if reached && res.status >= 200 && res.status < 300 {
			p.sent = true
			// Tried first from now on.
			p.urls[0], p.urls[i] = p.urls[i], p.urls[0]
			return
		}
	}
}

// Where Twitch's site sends its events, from the settings script the channel page
// loads; the known addresses if that can't be read.
@(private = "file")
points_lookup_urls :: proc(login: string, urls: ^[dynamic]string) {
	defer if len(urls) == 0 {
		for u in POINTS_TRACK_URLS {
			append(urls, strings.clone(u))
		}
	}
	page, ok := http_request(strings.concatenate({"https://www.twitch.tv/", login}, context.temp_allocator), allocator = context.temp_allocator)
	if !ok || page.status != 200 {
		return
	}
	script, found := settings_script_url(string(page.body))
	if !found {
		return
	}
	settings, got := http_request(script, allocator = context.temp_allocator)
	if !got || settings.status != 200 {
		return
	}
	for key in ([?]string{"spade_url", "beacon_url"}) {
		if url, has := settings_string(string(settings.body), key); has {
			append(urls, strings.clone(url))
		}
	}
}

// The site's settings script ("https://assets.twitch.tv/config/settings.<hash>.js")
// in a channel page.
settings_script_url :: proc(page: string) -> (url: string, ok: bool) {
	at := strings.index(page, "/config/settings.")
	if at < 0 {
		return "", false
	}
	start := strings.last_index(page[:at], "https://")
	end := strings.index(page[at:], ".js")
	if start < 0 || end < 0 || strings.contains_any(page[start:at], "\"' <>") {
		return "", false
	}
	return page[start:at + end + len(".js")], true
}

// A plain string value ("key":"value") from the settings script, with its "\/"
// unescaped. Allocated with the temp allocator.
settings_string :: proc(script, key: string) -> (value: string, ok: bool) {
	needle := strings.concatenate({"\"", key, "\":\""}, context.temp_allocator)
	at := strings.index(script, needle)
	if at < 0 {
		return "", false
	}
	rest := script[at + len(needle):]
	end := strings.index_byte(rest, '"')
	if end <= 0 {
		return "", false
	}
	value, _ = strings.replace_all(rest[:end], "\\/", "/", context.temp_allocator)
	return value, strings.has_prefix(value, "https://")
}

finish_points_job :: proc(app: ^App, p: ^Points_Job) {
	pts := &app.points
	pts.pending = false
	if len(p.urls) > 0 {
		points_destroy(pts)
		pts.urls, p.urls = p.urls, {}
	}
	if p.sent {
		log.debugf("channel points: reported a minute of %s to %s", p.login, pts.urls[0])
		if pts.warned {
			log.info("channel points: reporting watch time again")
			pts.warned = false
		}
		return
	}
	if !pts.warned {
		log.warnf("channel points: can't report watch time (last status %d); Twitch's addresses may be blocked or changed", p.status)
		pts.warned = true
	}
}
