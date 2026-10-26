package app

import "core:strings"

Language :: struct {
	code, name: string,
}

// The languages Twitch lets broadcasters pick, by how many stream in them.
LANGUAGES :: [?]Language {
	{"en", "English"},
	{"es", "Spanish"},
	{"pt", "Portuguese"},
	{"de", "German"},
	{"fr", "French"},
	{"ru", "Russian"},
	{"ja", "Japanese"},
	{"ko", "Korean"},
	{"zh", "Chinese"},
	{"zh-hk", "Cantonese"},
	{"it", "Italian"},
	{"pl", "Polish"},
	{"tr", "Turkish"},
	{"ar", "Arabic"},
	{"nl", "Dutch"},
	{"sv", "Swedish"},
	{"th", "Thai"},
	{"uk", "Ukrainian"},
	{"cs", "Czech"},
	{"hu", "Hungarian"},
	{"fi", "Finnish"},
	{"da", "Danish"},
	{"no", "Norwegian"},
	{"el", "Greek"},
	{"vi", "Vietnamese"},
	{"id", "Indonesian"},
	{"ms", "Malay"},
	{"tl", "Tagalog"},
	{"hi", "Hindi"},
	{"ro", "Romanian"},
	{"bg", "Bulgarian"},
	{"sk", "Slovak"},
	{"ca", "Catalan"},
	{"asl", "American Sign Language"},
	{"other", "Other"},
}

// The language's name, or "" if `code` isn't one Twitch has.
language_name :: proc(code: string) -> string {
	for l in LANGUAGES {
		if l.code == code {
			return l.name
		}
	}
	return ""
}

// The language a stream list asks Twitch for: the primary one when other
// languages are hidden. The followed channels are all shown, whatever their
// language: the user picked them.
language_fetch_filter :: proc(app: ^App, view: Browse_View) -> string {
	if !app.layout.language_hide || view == .Following {
		return ""
	}
	return app.layout.language
}

// Whether a stream on `view`'s list is grayed out, for not being in the primary
// language.
language_grayed :: proc(app: ^App, view: Browse_View, s: Stream) -> bool {
	l := &app.layout
	return l.language != "" && !l.language_hide && view != .Following && s.language != l.language
}

// Picks the primary language ("" for any) or whether others are hidden, saves,
// and has Top and the category fetched again when next shown.
language_set :: proc(app: ^App, code: string, hide: bool) {
	l := &app.layout
	if code != l.language {
		delete(l.language)
		l.language = strings.clone(code)
	}
	l.language_hide = hide
	layout_save(l)
	b := &app.browse
	for list in ([]^Stream_List{&b.top, &b.category}) {
		list.last_refresh = -BROWSE_REFRESH_MS
	}
}

// The header's language picker: whether other languages are grayed out or
// hidden, then every language, in columns.
Language_Menu :: struct {
	open:      bool,
	// Set while drawing.
	mode:      [2]Rect,
	// "Any language", then each of LANGUAGES.
	languages: [dynamic]Rect,
}

language_menu_destroy :: proc(m: ^Language_Menu) {
	delete(m.languages)
}

// The header's label for the picker.
language_label :: proc(app: ^App) -> string {
	if app.layout.language == "" {
		return "Any language"
	}
	return language_name(app.layout.language)
}

// A left click while the picker is open: picks what was clicked. Any click
// closes it (a pick of the mode leaves it open, to pick a language next), and
// goes no further.
language_menu_click :: proc(app: ^App, x, y: f32) -> bool {
	m := &app.browse.language_menu
	if !m.open {
		return false
	}
	for rect, i in m.mode {
		if in_rect(rect, x, y) {
			language_set(app, app.layout.language, i == 1)
			return true
		}
	}
	languages := LANGUAGES
	for rect, i in m.languages {
		if in_rect(rect, x, y) {
			language_set(app, "" if i == 0 else languages[i - 1].code, app.layout.language_hide)
			break
		}
	}
	m.open = false
	return true
}

// Below the header's label `at`, its right edge with the label's, kept on screen.
draw_language_menu :: proc(app: ^App, at: Rect, screen: Rect) {
	m := &app.browse.language_menu
	m.mode = {}
	clear(&m.languages)
	if !m.open {
		return
	}
	r := &app.assets.renderer
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	item_h := MENU_ITEM_HEIGHT * scale * r.text_scale
	pad := 12 * scale
	// Room for the check mark before each label (see draw_menu_item).
	label_pad := 2 * pad + line_height(r, .Regular, size)
	languages := LANGUAGES
	modes := [2]string{"Gray out other languages", "Hide other languages"}

	column_w: f32 = 0
	for l in languages {
		column_w = max(column_w, text_width(r, .Bold, size, l.name) + label_pad)
	}
	mode_w := max(text_width(r, .Bold, size, modes[0]), text_width(r, .Bold, size, modes[1])) + label_pad
	count := len(languages) + 1
	columns := clamp(int((screen.w - 2 * pad) / column_w), 1, 4)
	rows := (count + columns - 1) / columns
	menu_w := max(f32(columns) * column_w, mode_w)
	divider := 9 * scale
	menu_h := item_h * f32(2 + rows) + divider
	menu := Rect{max(pad, at.x + at.w - menu_w), at.y + at.h + 8 * scale, menu_w, menu_h}
	menu.x = min(menu.x, screen.w - menu_w)
	draw_rect(r, {menu.x - scale, menu.y - scale, menu.w + 2 * scale, menu.h + 2 * scale}, USER_CARD_BORDER)
	draw_rect(r, menu, USER_CARD_BACKGROUND)

	for label, i in modes {
		m.mode[i] = {menu.x, menu.y + f32(i) * item_h, menu.w, item_h}
		draw_menu_item(app, m.mode[i], label, app.layout.language_hide == (i == 1))
	}
	line_y := menu.y + 2 * item_h + divider / 2
	draw_rect(r, {menu.x + pad, line_y, menu.w - 2 * pad, scale}, USER_CARD_BORDER)
	top := menu.y + 2 * item_h + divider
	column_w = menu_w / f32(columns)
	for i in 0 ..< count {
		// Down each column, then across, so the list reads in order.
		item := Rect{menu.x + f32(i / rows) * column_w, top + f32(i % rows) * item_h, column_w, item_h}
		append(&m.languages, item)
		code := "" if i == 0 else languages[i - 1].code
		name := "Any language" if i == 0 else languages[i - 1].name
		draw_menu_item(app, item, fit_text(r, .Regular, size, name, column_w - label_pad), code == app.layout.language)
	}
}

// The stream's language, upper case, for its card's badge.
language_badge :: proc(s: Stream) -> string {
	if s.language == "" {
		return "?"
	}
	return strings.to_upper(s.language, context.temp_allocator)
}
