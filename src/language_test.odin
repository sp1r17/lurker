package app

import "core:testing"

@(test)
other_languages_gray_out_or_hide :: proc(t: ^testing.T) {
	app: App
	defer delete(app.layout.language)
	testing.expect_value(t, language_name("zh-hk"), "Cantonese")
	testing.expect_value(t, language_name("xx"), "")
	es := Stream{language = "es"}
	en := Stream{language = "en"}
	// Any language: nothing grayed or filtered.
	testing.expect(t, !language_grayed(&app, .Top, es))
	testing.expect_value(t, language_fetch_filter(&app, .Top), "")

	app.layout.language = "en"
	testing.expect(t, language_grayed(&app, .Top, es))
	testing.expect(t, language_grayed(&app, .Category, es))
	testing.expect(t, !language_grayed(&app, .Top, en))
	// The followed channels are all shown as they are.
	testing.expect(t, !language_grayed(&app, .Following, es))
	testing.expect_value(t, language_fetch_filter(&app, .Top), "")

	app.layout.language_hide = true
	testing.expect(t, !language_grayed(&app, .Top, es))
	testing.expect_value(t, language_fetch_filter(&app, .Top), "en")
	testing.expect_value(t, language_fetch_filter(&app, .Category), "en")
	testing.expect_value(t, language_fetch_filter(&app, .Following), "")
}

@(test)
language_is_saved_in_the_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l: Layout
	defer layout_destroy(&l)
	parse_layout(transmute([]byte)string(`{"language":"de","language_hide":true}`), &l)
	testing.expect_value(t, l.language, "de")
	testing.expect(t, l.language_hide)

	unknown: Layout
	defer layout_destroy(&unknown)
	parse_layout(transmute([]byte)string(`{"language":"klingon"}`), &unknown)
	testing.expect_value(t, unknown.language, "")
}
