package app

import "core:testing"

@(private = "file")
video :: proc(height, fps: int, bare := false) -> Quality {
	return {kind = .Video, height = height, fps = fps, bare = bare}
}

@(test)
renditions_come_from_stream_names :: proc(t: ^testing.T) {
	live := renditions_from_streams({"audio_only", "160p", "360p", "480p", "720p60", "936p60", "worst", "best"})
	testing.expect_value(t, live.count, 5)
	testing.expect_value(t, live.video[0], video(936, 60))
	testing.expect_value(t, live.video[1], video(720, 60))
	testing.expect_value(t, live.video[4], video(160, 30, bare = true))
	testing.expect(t, live.audio)
	vod := renditions_from_streams({"audio", "720p30", "1440p60", "720p60", "900p60_alt"})
	testing.expect_value(t, vod.count, 3)
	testing.expect_value(t, vod.video[0], video(1440, 60))
	testing.expect_value(t, vod.video[1], video(720, 60))
	testing.expect_value(t, vod.video[2], video(720, 30))
	clip := renditions_from_streams({"360p0", "1080p0", "worst", "best"})
	testing.expect_value(t, clip.video[0], video(1080, 0))
	testing.expect(t, !clip.audio)
}

@(test)
qualities_are_labelled_and_saved_exactly :: proc(t: ^testing.T) {
	testing.expect_value(t, quality_label(video(936, 60)), "936p60")
	testing.expect_value(t, quality_label(video(900, 30)), "900p")
	testing.expect_value(t, quality_label(video(480, 30, bare = true)), "480p")
	testing.expect_value(t, quality_label(video(720, 0)), "720p")
	testing.expect_value(t, quality_name(video(720, 0)), "720p0")
	for q in ([]Quality{QUALITY_SOURCE, QUALITY_AUDIO, video(936, 60), video(480, 30, bare = true), video(720, 0)}) {
		testing.expect_value(t, quality_from_label(quality_name(q)), q)
	}
	// As 0.8 saved them.
	testing.expect_value(t, quality_from_label("1080p"), video(1080, 30, bare = true))
	testing.expect_value(t, quality_from_label("Audio only"), QUALITY_AUDIO)
	testing.expect_value(t, quality_from_label("nonsense"), QUALITY_SOURCE)
}

@(test)
the_nearest_rendition_plays :: proc(t: ^testing.T) {
	r := renditions_from_streams({"audio_only", "160p", "360p", "480p", "720p", "720p60", "936p60"})
	testing.expect_value(t, quality_playing(QUALITY_SOURCE, r), video(936, 60))
	testing.expect_value(t, quality_playing(video(936, 60), r), video(936, 60))
	testing.expect_value(t, quality_playing(video(1080, 60), r), video(936, 60))
	testing.expect_value(t, quality_playing(video(900, 60), r), video(936, 60))
	testing.expect_value(t, quality_playing(video(720, 30, bare = true), r), video(720, 30, bare = true))
	testing.expect_value(t, quality_playing(video(720, 60), r), video(720, 60))
	testing.expect_value(t, quality_playing(video(540, 30), r), video(480, 30, bare = true))
	testing.expect_value(t, quality_playing(QUALITY_AUDIO, r), QUALITY_AUDIO)
	source_only := renditions_from_streams({"1080p60"})
	testing.expect_value(t, quality_playing(video(360, 30), source_only), video(1080, 60))
	testing.expect_value(t, quality_playing(QUALITY_AUDIO, source_only), video(1080, 60))
	// Unknown yet: as asked.
	testing.expect_value(t, quality_playing(video(900, 60), {}), video(900, 60))
}

@(test)
streamlink_is_asked_for_the_rendition :: proc(t: ^testing.T) {
	r := renditions_from_streams({"480p", "720p60", "936p60"})
	testing.expect_value(t, quality_streams(video(1080, 60), r), "936p60,best")
	testing.expect_value(t, quality_streams(video(480, 30, bare = true), r), "480p,best")
	testing.expect_value(t, quality_streams(QUALITY_SOURCE, {}), "best")
	testing.expect_value(t, quality_streams(video(720, 60), {}), "720p60,720p60,720p50,720p30,720p,720p0,best")
	testing.expect_value(t, quality_codecs(video(1440, 60), {}), "h264,h265,av1")
	testing.expect_value(t, quality_codecs(video(720, 60), r), "h264")
}

@(test)
a_blind_start_is_corrected :: proc(t: ^testing.T) {
	r := renditions_from_streams({"160p", "360p", "720p60", "1080p60"})
	// Asked for 1080p60 before: the same.
	testing.expect_value(t, quality_blind(video(1080, 60), r), quality_playing(video(1080, 60), r))
	// 480p isn't there: streamlink took Source, but 360p is nearer.
	testing.expect_value(t, quality_blind(video(480, 30, bare = true), r), video(1080, 60))
	testing.expect_value(t, quality_playing(video(480, 30, bare = true), r), video(360, 30, bare = true))
}

@(test)
the_menu_offers_the_streams_renditions :: proc(t: ^testing.T) {
	r := renditions_from_streams({"audio_only", "160p", "480p", "936p60"})
	choices, n := quality_choices(QUALITY_SOURCE, r)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, choices[0], QUALITY_SOURCE)
	testing.expect_value(t, choices[1], video(480, 30, bare = true))
	testing.expect_value(t, choices[2], video(160, 30, bare = true))
	testing.expect_value(t, choices[3], QUALITY_AUDIO)
	choices, n = quality_choices(video(900, 60), {})
	testing.expect_value(t, n, 3)
	testing.expect_value(t, choices[1], video(900, 60))
}
