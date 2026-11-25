package app

import "core:testing"

@(test)
mention_chime_is_quiet_and_ends_softly :: proc(t: ^testing.T) {
	chime := mention_chime()
	defer delete(chime)
	testing.expect_value(t, len(chime), int(0.45 * MENTION_SOUND_RATE))
	loudest: f32
	for s in chime {
		loudest = max(loudest, abs(s))
	}
	testing.expect(t, loudest > 0.1 && loudest < 0.5)
	testing.expect_value(t, chime[len(chime) - 1], 0)
}
