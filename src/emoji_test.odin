package app

import "core:strings"
import "core:testing"

@(private = "file")
EMOJI_SAMPLE :: `[
	{"unified":"1F600","non_qualified":null,"image":"1f600.png","has_img_google":true},
	{"unified":"00A9-FE0F","non_qualified":"00A9","image":"00a9-fe0f.png","has_img_google":true},
	{"unified":"1F468","non_qualified":null,"image":"1f468.png","has_img_google":true,
	 "skin_variations":{"1F3FB":{"unified":"1F468-1F3FB","non_qualified":null,"image":"1f468-1f3fb.png"}}},
	{"unified":"1F468-200D-1F469-200D-1F467","non_qualified":null,"image":"family.png","has_img_google":true},
	{"unified":"2764-FE0F-200D-1F525","non_qualified":"2764-200D-1F525","image":"heart-fire.png","has_img_google":true}
]`

@(test)
emoji_matching_rules :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	table: Emoji_Table
	defer emoji_table_destroy(&table)
	testing.expect(t, parse_emoji_data(transmute([]byte)string(EMOJI_SAMPLE), &table))

	// The longest sequence wins: a family, not three people.
	text := "hi 👨‍👩‍👧!"
	start, end, image, found := find_emoji(&table, text, 0)
	testing.expect(t, found)
	testing.expect_value(t, image, "family.png")
	testing.expect_value(t, text[start:end], "👨‍👩‍👧")

	_, _, skin, _ := find_emoji(&table, "👨🏻", 0)
	testing.expect_value(t, skin, "1f468-1f3fb.png")

	// A lone © is text unless it asks for emoji presentation (FE0F).
	_, _, _, plain := find_emoji(&table, "© 2026", 0)
	testing.expect(t, !plain)
	_, _, qualified, _ := find_emoji(&table, "©️", 0)
	testing.expect_value(t, qualified, "00a9-fe0f.png")

	// A ZWJ sequence missing its FE0F still matches.
	_, _, fire, _ := find_emoji(&table, "❤‍🔥", 0)
	testing.expect_value(t, fire, "heart-fire.png")
}

@(test)
emoji_split_messages :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	table: Emoji_Table
	defer emoji_table_destroy(&table)
	parse_emoji_data(transmute([]byte)string(EMOJI_SAMPLE), &table)

	m := system_message("x")
	defer destroy_chat_message(m)
	m.kind = .Chat
	destroy_fragments(m.fragments[:])
	clear(&m.fragments)
	append(&m.fragments, Fragment{kind = .Text, text = strings.clone("hi😀 there 😀")})
	apply_emoji(&m, &table)

	testing.expect_value(t, len(m.fragments), 4)
	testing.expect_value(t, m.fragments[0].text, "hi")
	testing.expect(t, m.fragments[1].emoji)
	// "hi😀" has no space between: the emoji joins the word.
	testing.expect(t, m.fragments[1].attached)
	testing.expect_value(t, m.fragments[1].url_1x, "https://cdn.jsdelivr.net/npm/emoji-datasource-google@16.0.0/img/google/64/1f600.png")
	testing.expect_value(t, m.fragments[2].text, " there ")
	testing.expect(t, !m.fragments[3].attached)
}
