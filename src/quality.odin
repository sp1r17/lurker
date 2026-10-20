package app

import "core:strings"

Quality :: enum {
	Source,
	P1080,
	P720,
	P480,
	P360,
	Audio,
}

@(rodata)
QUALITY_LABELS := [Quality]string {
	.Source = "Source",
	.P1080  = "1080p",
	.P720   = "720p",
	.P480   = "480p",
	.P360   = "360p",
	.Audio  = "Audio only",
}

// What streamlink is asked for, first match wins. Twitch names renditions with
// their frame rate ("480p30"), and streamlink matches names exactly, so both rates
// are listed; the fallbacks keep a channel without that rendition playing.
@(rodata)
QUALITY_STREAMS := [Quality]string {
	.Source = "best",
	.P1080  = "1080p60,1080p30,1080p,best",
	.P720   = "720p60,720p30,720p,best",
	.P480   = "480p60,480p30,480p,360p30,360p,worst",
	.P360   = "360p60,360p30,360p,worst",
	.Audio  = "audio_only",
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
