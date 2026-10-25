package app

import "core:testing"

@(test)
chat_link_finds_links :: proc(t: ^testing.T) {
	Case :: struct {
		word, link, url: string,
	}
	cases := []Case {
		{"https://example.com/a?b=c", "https://example.com/a?b=c", "https://example.com/a?b=c"},
		{"(http://x.org/path).", "http://x.org/path", "http://x.org/path"},
		{"twitch.tv/moonmoon", "twitch.tv/moonmoon", "https://twitch.tv/moonmoon"},
		{"www.example.zz,", "www.example.zz", "https://www.example.zz"},
		{"YouTube.com", "YouTube.com", "https://YouTube.com"},
	}
	for c in cases {
		link, url, ok := chat_link(c.word)
		testing.expectf(t, ok, "%q is a link", c.word)
		testing.expect_value(t, link, c.link)
		testing.expect_value(t, url, c.url)
	}
}

@(test)
chat_link_skips_words :: proc(t: ^testing.T) {
	for word in ([]string{"hello", "end.of", "v1.2", "3.14", "a..com", ".com", "https://", "https://nodot", "e.g.", "file.exe", "@name"}) {
		_, _, ok := chat_link(word)
		testing.expectf(t, !ok, "%q isn't a link", word)
	}
}
