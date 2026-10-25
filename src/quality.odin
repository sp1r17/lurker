package app

import "core:strings"

Quality :: enum {
	Source,
	P1440,
	P1080,
	P720,
	P480,
	P360,
	Audio,
}

@(rodata)
QUALITY_LABELS := [Quality]string {
	.Source = "Source",
	.P1440  = "1440p",
	.P1080  = "1080p",
	.P720   = "720p",
	.P480   = "480p",
	.P360   = "360p",
	.Audio  = "Audio only",
}

// What streamlink is asked for, first match wins. Twitch names renditions with
// their frame rate ("480p30", "720p0" for clips), and streamlink matches names
// exactly, so each is listed; the fallbacks keep a channel without that rendition
// playing. Past broadcasts call the audio "audio".
@(rodata)
QUALITY_STREAMS := [Quality]string {
	.Source = "best",
	.P1440  = "1440p60,1440p30,1440p0,1440p,best",
	.P1080  = "1080p60,1080p30,1080p0,1080p,best",
	.P720   = "720p60,720p30,720p0,720p,best",
	.P480   = "480p60,480p30,480p0,480p,360p30,360p0,360p,worst",
	.P360   = "360p60,360p30,360p0,360p,worst",
	.Audio  = "audio_only,audio",
}

Quality_Set :: bit_set[Quality]

// The qualities a stream has, from streamlink's names for its renditions. Source
// is always there.
qualities_from_streams :: proc(names: []string) -> Quality_Set {
	found := Quality_Set{.Source}
	for name in names {
		if name == "audio_only" || name == "audio" {
			found += {.Audio}
			continue
		}
		for q in Quality.P1440 ..= Quality.P360 {
			if strings.has_prefix(name, QUALITY_LABELS[q]) {
				found += {q}
			}
		}
	}
	return found
}

// What plays when `q` is asked for and the stream has `available`: the first of its
// QUALITY_STREAMS there, Source for "best", and the lowest there for "worst".
quality_playing :: proc(q: Quality, available: Quality_Set) -> Quality {
	if q in available {
		return q
	}
	names := QUALITY_STREAMS[q]
	for name in strings.split_iterator(&names, ",") {
		switch name {
		case "best":
			return .Source
		case "worst":
			for i := int(Quality.P360); i >= int(Quality.Source); i -= 1 {
				if Quality(i) in available {
					return Quality(i)
				}
			}
		case:
			if found := qualities_from_streams({name}) - {.Source}; found != {} {
				for f in found {
					if f in available {
						return f
					}
				}
			}
		}
	}
	return .Source
}

// The codecs streamlink tells Twitch the player can play. Twitch only sends 1440p
// as H.265 or AV1, and only when asked; the lower qualities stay H.264, which
// every machine can decode.
quality_codecs :: proc(q: Quality) -> string {
	return "h264,h265,av1" if q == .Source || q == .P1440 else "h264"
}

// The quality saved under `label` ("720p"), or Source.
quality_from_label :: proc(label: string) -> Quality {
	for name, q in QUALITY_LABELS {
		if strings.equal_fold(name, label) {
			return q
		}
	}
	return .Source
}

Qualities_Job :: struct {
	page:      string,
	client_id: string,
	token:     string,
	session:   int,
	found:     Quality_Set,
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
	w.qualities = p.found
}

// The qualities the quality menu offers: the stream's, or all of them until those
// are known.
watch_qualities :: proc(app: ^App) -> Quality_Set {
	return app.watch.qualities if app.watch.qualities != {} else ~Quality_Set{}
}
