package app

import "core:testing"

@(test)
ended_streams_are_checked_less_often :: proc(t: ^testing.T) {
	app: App
	w := &app.watch
	app.assets.now_ms = 1000
	// The stream ended while watching it.
	stream_retry_later(&app)
	testing.expect_value(t, w.status, Stream_Status.Ended)
	testing.expect_value(t, w.retry_at, 6000)
	// Each check that finds it still offline waits longer, up to five minutes.
	expected := []int{10_000, 20_000, 40_000, 80_000, 160_000, 300_000, 300_000}
	for delay in expected {
		w.retrying = true
		stream_retry_later(&app)
		testing.expect_value(t, w.retry_at, 1000 + delay)
		testing.expect(t, !w.retrying)
	}
	// Not due yet; not checking while a past broadcast plays, or off the watch screen.
	app.screen = .Watch
	testing.expect_value(t, stream_retry_tick(&app), 300_000)
	w.playing_vod = true
	testing.expect_value(t, stream_retry_tick(&app), -1)
}
