package app

import "core:testing"

// Plays to `until`, the position moving `moves` (else standing still), in steps
// of 250 ms; returns whether it was time to lower.
@(private = "file")
play :: proc(b: ^Buffering, now: ^int, pos: ^f64, until: int, moves: bool) -> (lower: bool) {
	for now^ < until {
		now^ += 250
		if moves {
			pos^ += 0.25
		}
		if buffering_update(b, now^, pos^, false) {
			lower = true
		}
	}
	return
}

@(test)
buffering_lowers_after_three_stalls :: proc(t: ^testing.T) {
	b: Buffering
	now, pos := 1, 0.0
	testing.expect(t, !play(&b, &now, &pos, 5_000, true))
	// Two stalls: not yet. A short hiccup doesn't count.
	testing.expect(t, !play(&b, &now, &pos, 7_000, false))
	testing.expect(t, !play(&b, &now, &pos, 10_000, true))
	testing.expect(t, !play(&b, &now, &pos, 12_000, false))
	testing.expect(t, !play(&b, &now, &pos, 15_000, true))
	testing.expect(t, !play(&b, &now, &pos, 15_500, false))
	testing.expect(t, !play(&b, &now, &pos, 18_000, true))
	// The third within a minute.
	testing.expect(t, play(&b, &now, &pos, 20_000, false))
	testing.expect_value(t, b.count, 0)
}

@(test)
buffering_forgets_old_stalls :: proc(t: ^testing.T) {
	b: Buffering
	now, pos := 1, 0.0
	play(&b, &now, &pos, 5_000, true)
	play(&b, &now, &pos, 7_000, false)
	play(&b, &now, &pos, 40_000, true)
	play(&b, &now, &pos, 42_000, false)
	// The first is over a minute old by the third.
	play(&b, &now, &pos, 80_000, true)
	testing.expect(t, !play(&b, &now, &pos, 82_000, false))
	// Paused isn't a stall.
	for _ in 0 ..< 20 {
		now += 250
		testing.expect(t, !buffering_update(&b, now, pos, true))
	}
}

@(test)
quality_lower_steps_down_one :: proc(t: ^testing.T) {
	r := renditions_from_streams({"1080p60", "720p60", "480p", "audio_only"})
	q1080, _ := quality_from_name("1080p60")
	q720, _ := quality_from_name("720p60")
	q480, _ := quality_from_name("480p")
	lower, ok := quality_lower(q1080, r)
	testing.expect(t, ok)
	testing.expect_value(t, lower, q720)
	// Source plays the best: one down from it.
	lower, ok = quality_lower(QUALITY_SOURCE, r)
	testing.expect_value(t, lower, q720)
	// Not below the lowest video.
	_, ok = quality_lower(q480, r)
	testing.expect(t, !ok)
	_, ok = quality_lower(q1080, {})
	testing.expect(t, !ok)
}
