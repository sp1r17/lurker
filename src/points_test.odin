package app

import "core:testing"

@(test)
finds_settings_script :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	page := `<link rel="preload" href="https://assets.twitch.tv/config/manifest.json"><script src="https://assets.twitch.tv/config/settings.ceb8f706123d163ec15c38c1798c7270.js" crossorigin="anonymous"></script>`
	url, ok := settings_script_url(page)
	testing.expect(t, ok)
	testing.expect_value(t, url, "https://assets.twitch.tv/config/settings.ceb8f706123d163ec15c38c1798c7270.js")

	_, ok = settings_script_url(`<script src="/config/settings.js"></script>`)
	testing.expect(t, !ok)
	_, ok = settings_script_url("no settings here")
	testing.expect(t, !ok)
}

@(test)
reads_settings_strings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	script := `window.__twilightSettings = {"beacon_url":"https://beacon.twitch.tv/track","spade_url":"https:\/\/spade.twitch.tv\/track","empty":""}`
	spade, ok := settings_string(script, "spade_url")
	testing.expect(t, ok)
	testing.expect_value(t, spade, "https://spade.twitch.tv/track")
	beacon, _ := settings_string(script, "beacon_url")
	testing.expect_value(t, beacon, "https://beacon.twitch.tv/track")
	_, ok = settings_string(script, "empty")
	testing.expect(t, !ok)
	_, ok = settings_string(script, "missing")
	testing.expect(t, !ok)
}
