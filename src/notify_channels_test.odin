package app

import "core:testing"

@(test)
live_notifications_follow_the_channel_lists :: proc(t: ^testing.T) {
	l: Layout
	defer layout_destroy(&l)
	testing.expect(t, parse_layout(transmute([]byte)string(`{"splits":{},"notify_muted":["lirik","Not a login!"],"notify_chosen":["moonmoon"]}`), &l))
	testing.expect_value(t, len(l.notify_muted), 1)
	// All but those muted.
	testing.expect(t, !notify_wanted(&l, "lirik"))
	testing.expect(t, notify_wanted(&l, "northernlion"))
	// Only those chosen.
	l.notify_only = true
	testing.expect(t, notify_wanted(&l, "moonmoon"))
	testing.expect(t, !notify_wanted(&l, "northernlion"))
	testing.expect(t, !notify_wanted(&l, "lirik"))
}
