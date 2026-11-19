package app

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

Quality_Kind :: enum {
	Source,
	Video,
	Audio,
}

// A quality to play: Source (the stream's best), audio only, or a rendition by
// the height and frame rate in streamlink's name for it ("936p60"). Twitch leaves
// the frame rate out of its 30 fps live renditions ("480p"): `bare`, and fps 30.
// Clips' are "720p0".
Quality :: struct {
	kind:   Quality_Kind,
	height: int,
	fps:    int,
	bare:   bool,
}

QUALITY_SOURCE :: Quality {
	kind = .Source,
}
QUALITY_AUDIO :: Quality {
	kind = .Audio,
}

MAX_RENDITIONS :: 16

// The renditions a stream has, from streamlink: its videos, best first (so
// video[0] is Source), and whether it has audio only. None until known.
Renditions :: struct {
	video:  [MAX_RENDITIONS]Quality,
	count:  int,
	audio:  bool,
	// Some taller than the highest quality allowed were left out
	// (renditions_capped): video[0] isn't Source.
	capped: bool,
}

// The highest quality allowed (Layout.max_height): any, or a height.
MAX_HEIGHTS :: [?]int{0, 1080, 720, 480, 360}

// `r` without the renditions taller than `max_height` (0 for no limit), keeping
// the lowest should they all be.
renditions_capped :: proc(r: Renditions, max_height: int) -> Renditions {
	if max_height <= 0 || r.count == 0 {
		return r
	}
	r := r
	capped := r
	capped.count = 0
	for v in r.video[:r.count] {
		if v.height <= max_height {
			capped.video[capped.count] = v
			capped.count += 1
		}
	}
	if capped.count == 0 {
		capped.video[0] = r.video[r.count - 1]
		capped.count = 1
	}
	capped.capped = capped.count < r.count
	return capped
}

// What to ask for before the renditions are known, when `q` is wanted and the
// highest allowed is `max_height` (0 for no limit): the limit, if `q` (Source,
// say) could be above it.
quality_capped :: proc(q: Quality, max_height: int) -> Quality {
	if max_height <= 0 || q.kind == .Audio || (q.kind == .Video && q.height <= max_height) {
		return q
	}
	return {kind = .Video, height = max_height, fps = 60}
}

renditions_known :: proc(r: Renditions) -> bool {
	return r.count > 0
}

// The rendition streamlink's `name` is ("720p60", "480p", "1080p0"); false for any
// other name ("best", "audio_only", "720p60_alt").
quality_from_name :: proc(name: string) -> (q: Quality, ok: bool) {
	p := strings.index_byte(name, 'p')
	if p <= 0 || !all_digits(name[:p]) || !all_digits(name[p + 1:]) {
		return {}, false
	}
	q = {
		kind   = .Video,
	}
	q.height, _ = strconv.parse_int(name[:p], 10)
	if p + 1 == len(name) {
		q.fps = 30
		q.bare = true
	} else {
		q.fps, _ = strconv.parse_int(name[p + 1:], 10)
	}
	return q, true
}

@(private = "file")
all_digits :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// Streamlink's name for `q` ("720p60", "480p"); also how it's saved. Allocated
// with the temp allocator.
quality_name :: proc(q: Quality) -> string {
	switch q.kind {
	case .Source:
		return "Source"
	case .Audio:
		return "Audio only"
	case .Video:
	}
	return fmt.tprintf("%dp", q.height) if q.bare else fmt.tprintf("%dp%d", q.height, q.fps)
}

// What the quality menu calls `q`: like Twitch, the frame rate only when it's
// over 30 ("936p60", "720p"). Allocated with the temp allocator.
quality_label :: proc(q: Quality) -> string {
	if q.kind == .Video && q.fps <= 30 {
		return fmt.tprintf("%dp", q.height)
	}
	return quality_name(q)
}

// The quality saved as `label` ("720p60", from quality_name), or Source.
quality_from_label :: proc(label: string) -> Quality {
	if strings.equal_fold(label, "Audio only") {
		return QUALITY_AUDIO
	}
	if q, ok := quality_from_name(label); ok {
		return q
	}
	return QUALITY_SOURCE
}

// The renditions a stream has, from streamlink's names for its streams.
renditions_from_streams :: proc(names: []string) -> Renditions {
	r: Renditions
	for name in names {
		if name == "audio_only" || name == "audio" {
			r.audio = true
			continue
		}
		q, ok := quality_from_name(name)
		if !ok || r.count == MAX_RENDITIONS || slice.contains(r.video[:r.count], q) {
			continue
		}
		r.video[r.count] = q
		r.count += 1
	}
	slice.sort_by(r.video[:r.count], proc(a, b: Quality) -> bool {
		return a.height > b.height || (a.height == b.height && a.fps > b.fps)
	})
	return r
}

// What plays when `q` is asked for from a stream with `r`: the rendition of the
// height nearest to it (the higher one, between two as near), in the frame rate
// nearest to it. Source is the best rendition; audio only, when there's none, too.
// `q` itself until the renditions are known.
quality_playing :: proc(q: Quality, r: Renditions) -> Quality {
	r := r
	if !renditions_known(r) {
		return q
	}
	switch q.kind {
	case .Source:
		return r.video[0]
	case .Audio:
		return QUALITY_AUDIO if r.audio else r.video[0]
	case .Video:
	}
	best := r.video[0]
	for v in r.video[1:r.count] {
		dh, best_dh := abs(v.height - q.height), abs(best.height - q.height)
		if dh < best_dh || (v.height == best.height && abs(v.fps - q.fps) < abs(best.fps - q.fps)) {
			best = v
		}
	}
	return best
}

// What streamlink is asked for, first match wins, when `q` is wanted from a
// stream with `r`: the rendition quality_playing picks. Before the renditions are
// known, it's `q`'s height in the usual frame rates, then Source (quality_blind);
// past broadcasts call the audio "audio". Allocated with the temp allocator.
quality_streams :: proc(q: Quality, r: Renditions) -> string {
	if renditions_known(r) {
		playing := quality_playing(q, r)
		if playing.kind == .Video {
			// Source still, should Twitch not have it for the codecs allowed.
			return fmt.tprintf("%s,best", quality_name(playing))
		}
	}
	switch q.kind {
	case .Source:
		return "best"
	case .Audio:
		return "audio_only,audio,best"
	case .Video:
	}
	names := make([dynamic]string, context.temp_allocator)
	for c in blind_candidates(q) {
		append(&names, quality_name(c))
	}
	append(&names, "best")
	return strings.join(names[:], ",", context.temp_allocator)
}

// `q`'s height in each frame rate, `q`'s own first.
@(private = "file")
blind_candidates :: proc(q: Quality) -> [6]Quality {
	h := q.height
	return {
		q,
		{kind = .Video, height = h, fps = 60},
		{kind = .Video, height = h, fps = 50},
		{kind = .Video, height = h, fps = 30},
		{kind = .Video, height = h, fps = 30, bare = true},
		{kind = .Video, height = h, fps = 0},
	}
}

// What quality_streams asked for before the renditions were known plays, now
// they are: so the stream can be restarted if it isn't quality_playing's pick.
quality_blind :: proc(q: Quality, r: Renditions) -> Quality {
	r := r
	switch q.kind {
	case .Source:
		return r.video[0]
	case .Audio:
		return QUALITY_AUDIO if r.audio else r.video[0]
	case .Video:
	}
	for c in blind_candidates(q) {
		if slice.contains(r.video[:r.count], c) {
			return c
		}
	}
	return r.video[0]
}

// The codecs streamlink tells Twitch the player can play. Twitch only sends 1440p
// as H.265 or AV1, and only when asked; 1080p and below stay H.264, which every
// machine can decode.
quality_codecs :: proc(q: Quality, r: Renditions) -> string {
	playing := quality_playing(q, r)
	return "h264,h265,av1" if playing.kind == .Source || playing.height > 1080 else "h264"
}

// The quality menu's choices: Source (the best rendition), the stream's other
// renditions, then audio only. Until those are known: Source, the saved quality
// `q`, audio only.
quality_choices :: proc(q: Quality, r: Renditions) -> (choices: [MAX_RENDITIONS + 2]Quality, n: int) {
	r := r
	choices[0] = QUALITY_SOURCE
	n = 1
	if renditions_known(r) {
		for v in r.video[1:r.count] {
			choices[n] = v
			n += 1
		}
	} else if q.kind == .Video {
		choices[n] = q
		n += 1
	}
	if r.audio || !renditions_known(r) {
		choices[n] = QUALITY_AUDIO
		n += 1
	}
	return
}

// The quality to ask for: the saved one, within the highest allowed.
watch_quality :: proc(app: ^App) -> Quality {
	return quality_capped(app.layout.quality, app.layout.max_height)
}

Qualities_Job :: struct {
	page:      string,
	client_id: string,
	token:     string,
	session:   int,
	found:     Renditions,
	ok:        bool,
}

destroy_qualities_job :: proc(p: ^Qualities_Job) {
	delete(p.page)
	delete(p.client_id)
	delete(p.token)
}

// Looks up which qualities the stream at `page` has, for the quality menu, unless
// they're known or being looked up.
qualities_request :: proc(app: ^App, page: string) {
	w := &app.watch
	if w.qualities_page == page {
		return
	}
	delete(w.qualities_page)
	w.qualities_page = strings.clone(page)
	w.qualities = {}
	job := Qualities_Job {
		page    = strings.clone(page),
		session = app.session,
	}
	if app.signed_in {
		job.client_id = strings.clone(app.client_id)
		job.token = strings.clone(app.auth.access_token)
	}
	jobs_add(&app.assets.jobs, run_qualities_job, job)
}

@(private = "file")
run_qualities_job :: proc(job: ^Job) {
	p := &job.payload.(Qualities_Job)
	p.found, p.ok = streamlink_qualities(p.page, p.client_id, p.token)
}

finish_qualities_job :: proc(app: ^App, p: ^Qualities_Job) {
	w := &app.watch
	if app.screen != .Watch || p.session != app.session || p.page != w.qualities_page || !p.ok {
		return
	}
	w.qualities = renditions_capped(p.found, app.layout.max_height)
	watch_renditions_found(app)
}

