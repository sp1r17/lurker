package app

import "core:testing"

@(test)
qualities_come_from_stream_names :: proc(t: ^testing.T) {
	live := qualities_from_streams({"audio_only", "160p", "360p", "480p", "720p60", "1080p60", "worst", "best"})
	testing.expect_value(t, live, Quality_Set{.Source, .P1080, .P720, .P480, .P360, .Audio})
	vod := qualities_from_streams({"audio", "720p60", "1440p60"})
	testing.expect_value(t, vod, Quality_Set{.Source, .P1440, .P720, .Audio})
	clip := qualities_from_streams({"360p0", "480p0", "720p0", "1080p0", "worst", "best"})
	testing.expect_value(t, clip, Quality_Set{.Source, .P1080, .P720, .P480, .P360})
}

@(test)
missing_qualities_fall_back :: proc(t: ^testing.T) {
	small := Quality_Set{.Source, .P720, .P360, .Audio}
	testing.expect_value(t, quality_playing(.P720, small), Quality.P720)
	testing.expect_value(t, quality_playing(.P1080, small), Quality.Source)
	testing.expect_value(t, quality_playing(.P480, small), Quality.P360)
	only_source := Quality_Set{.Source, .Audio}
	testing.expect_value(t, quality_playing(.P360, only_source), Quality.Source)
	testing.expect_value(t, quality_playing(.Audio, only_source), Quality.Audio)
}
