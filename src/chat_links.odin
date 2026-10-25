package app

import "core:strings"

// Endings a link written without "https://" must have to count as one, so that
// "end.of" or "v1.2" in a message stay plain words.
@(rodata)
LINK_TLDS := [?]string {
	"com", "net", "org", "tv", "gg", "io", "me", "co", "app", "dev", "ly", "be", "uk", "de", "fr", "es", "it", "nl",
	"ru", "jp", "ca", "us", "xyz", "info", "link", "live", "gl", "to", "fm", "ai", "so", "sh",
}

// The part of a chat word that's a link, and the address to open for it ("https://"
// added when it's written without). Brackets and punctuation around it aren't part of
// it. `link` points into `word`; `url` is allocated with the temp allocator.
chat_link :: proc(word: string) -> (link, url: string, ok: bool) {
	link = strings.trim_left(word, "(<\"'")
	link = strings.trim_right(link, ")>\"',.!?:;")
	lower := strings.to_lower(link, context.temp_allocator)
	if strings.has_prefix(lower, "https://") || strings.has_prefix(lower, "http://") {
		_, _, rest := strings.partition(link, "://")
		if !valid_host(host_of(rest)) {
			return "", "", false
		}
		return link, link, true
	}
	host := host_of(lower)
	if !valid_host(host) {
		return "", "", false
	}
	tld := host[strings.last_index_byte(host, '.') + 1:]
	known := strings.has_prefix(host, "www.")
	for t in LINK_TLDS {
		known ||= tld == t
	}
	if !known {
		return "", "", false
	}
	return link, strings.concatenate({"https://", link}, context.temp_allocator), true
}

// "host.tld" from "host.tld:8080/path?q", lowercase if `s` is.
@(private = "file")
host_of :: proc(s: string) -> string {
	end := strings.index_any(s, "/?#")
	host := s[:end] if end >= 0 else s
	if colon := strings.index_byte(host, ':'); colon >= 0 {
		host = host[:colon]
	}
	return host
}

// Labels of letters, digits and hyphens, at least two, the last all letters.
@(private = "file")
valid_host :: proc(host: string) -> bool {
	dot := strings.last_index_byte(host, '.')
	if dot <= 0 || dot == len(host) - 1 {
		return false
	}
	for label in strings.split(host, ".", context.temp_allocator) {
		if label == "" {
			return false
		}
		for c in label {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	for c in host[dot + 1:] {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return len(host) - dot - 1 >= 2
}
