package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Emoji drawn as images from Google's set (the look of Noto Color Emoji), as
// Chatterino does, rather than from a font: the fonts we can rasterize have no
// colour emoji. emoji-datasource lists every emoji sequence with its image.
EMOJI_DATA_URL :: "https://cdn.jsdelivr.net/npm/emoji-datasource-google@16.0.0/emoji.json"
// Only the 64 px images are published in the npm package.
EMOJI_IMAGE_URL :: "https://cdn.jsdelivr.net/npm/emoji-datasource-google@16.0.0/img/google/64/%s"
// The longest sequence in the data is 8 code points.
EMOJI_MAX_CODEPOINTS :: 10

// Emoji sequences (as UTF-8) -> image file name. Owned.
Emoji_Table :: struct {
	images: map[string]string,
	// The first code point of every sequence, to skip text quickly.
	starts: map[rune]struct{},
}

emoji_table_destroy :: proc(t: ^Emoji_Table) {
	for seq, image in t.images {
		delete(seq)
		delete(image)
	}
	delete(t.images)
	delete(t.starts)
}

// "1F468-200D-1F469" -> the UTF-8 for those code points. Allocated with the temp
// allocator; "" if malformed.
@(private = "file")
codepoints_to_utf8 :: proc(hex: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	rest := hex
	for part in strings.split_iterator(&rest, "-") {
		cp, ok := strconv.parse_u64_of_base(part, 16)
		if !ok || cp > 0x10FFFF {
			return ""
		}
		strings.write_rune(&sb, rune(cp))
	}
	return strings.to_string(sb)
}

// Builds the table from emoji-datasource's emoji.json. Every fully qualified
// sequence is matched; a sequence missing its FE0F selectors only if it's several
// code points (keyboards often drop FE0F inside ZWJ sequences). A lone character
// without FE0F, like "©" or "❤", is text by default in Unicode, so it stays text.
parse_emoji_data :: proc(body: []byte, t: ^Emoji_Table) -> bool {
	Variant :: struct {
		unified:       string,
		non_qualified: string,
		image:         string,
	}
	Entry :: struct {
		unified:         string,
		non_qualified:   string,
		image:           string,
		has_img_google:  bool,
		skin_variations: map[string]Variant,
	}
	entries: []Entry
	if json.unmarshal(body, &entries, allocator = context.temp_allocator) != nil {
		return false
	}
	add :: proc(t: ^Emoji_Table, hex, image: string, qualified: bool) {
		if hex == "" || image == "" {
			return
		}
		if !qualified && strings.count(hex, "-") == 0 {
			return
		}
		seq := codepoints_to_utf8(hex)
		if seq == "" || seq in t.images {
			return
		}
		t.images[strings.clone(seq)] = strings.clone(image)
		first, _ := utf8.decode_rune_in_string(seq)
		t.starts[first] = {}
	}
	for e in entries {
		if !e.has_img_google {
			continue
		}
		add(t, e.unified, e.image, true)
		add(t, e.non_qualified, e.image, false)
		for _, v in e.skin_variations {
			add(t, v.unified, v.image, true)
			add(t, v.non_qualified, v.image, false)
		}
	}
	return len(t.images) > 0
}

// The next emoji in `text` at or after byte `from`: its byte range and image.
// Longest sequence wins, so a ZWJ family is one emoji, not several.
find_emoji :: proc(t: ^Emoji_Table, text: string, from: int) -> (start, end: int, image: string, found: bool) {
	if len(t.images) == 0 {
		return
	}
	for i := from; i < len(text); {
		r, n := utf8.decode_rune_in_string(text[i:])
		if r not_in t.starts {
			i += n
			continue
		}
		// Ends of the next few code points, longest candidate first.
		ends: [EMOJI_MAX_CODEPOINTS]int
		count := 0
		for j := i; j < len(text) && count < EMOJI_MAX_CODEPOINTS; count += 1 {
			_, m := utf8.decode_rune_in_string(text[j:])
			j += m
			ends[count] = j
		}
		for k := count; k > 0; k -= 1 {
			if img, ok := t.images[text[i:ends[k - 1]]]; ok {
				return i, ends[k - 1], img, true
			}
		}
		i += n
	}
	return
}

emoji_url :: proc(image: string) -> string {
	return fmt.tprintf(EMOJI_IMAGE_URL, image)
}

// Splits the message's text fragments around emoji, which become image fragments.
apply_emoji :: proc(m: ^Chat_Message, t: ^Emoji_Table) {
	if len(t.images) == 0 {
		return
	}
	old := m.fragments
	m.fragments = make([dynamic]Fragment)
	for f in old {
		if f.kind != .Text {
			append(&m.fragments, f)
			continue
		}
		text := f.text
		pos := 0
		attached := f.attached
		for {
			start, end, image, found := find_emoji(t, text, pos)
			if !found {
				break
			}
			if start > pos {
				append(&m.fragments, Fragment{kind = .Text, text = strings.clone(text[pos:start]), attached = attached})
			}
			append(
				&m.fragments,
				Fragment {
					kind = .Emote,
					text = strings.clone(text[start:end]),
					url_1x = strings.clone(emoji_url(image)),
					emoji = true,
					// Joined to what's before unless whitespace separates them.
					attached = !is_space_before(text, start) if start > 0 else attached,
				},
			)
			pos = end
			attached = true
		}
		if pos == 0 {
			append(&m.fragments, f)
			continue
		}
		if pos < len(text) {
			append(&m.fragments, Fragment{kind = .Text, text = strings.clone(text[pos:]), attached = attached})
		}
		delete(f.text)
	}
	delete(old)
}

@(private = "file")
is_space_before :: proc(text: string, i: int) -> bool {
	c := text[i - 1]
	return c == ' ' || c == '\t'
}

Emoji_Job :: struct {
	ok:    bool,
	table: Emoji_Table,
}

destroy_emoji_job :: proc(p: ^Emoji_Job) {
	emoji_table_destroy(&p.table)
}

emoji_request :: proc(jobs: ^Jobs) {
	jobs_add(jobs, run_emoji_job, Emoji_Job{})
}

@(private = "file")
run_emoji_job :: proc(job: ^Job) {
	p := &job.payload.(Emoji_Job)
	// The URL names a version, so a cached copy is as good as a download.
	res, from_cache, ok := cached_get(EMOJI_DATA_URL)
	if !ok || res.status != 200 {
		log.warn("can't load the emoji list; emoji show as text")
		return
	}
	p.ok = parse_emoji_data(res.body, &p.table)
	if !p.ok && from_cache {
		cache_forget(EMOJI_DATA_URL)
	}
}

finish_emoji_job :: proc(a: ^Assets, p: ^Emoji_Job) {
	if !p.ok {
		return
	}
	emoji_table_destroy(&a.emoji)
	a.emoji, p.table = p.table, {}
	log.infof("loaded %d emoji", len(a.emoji.images))
}

// Draws one line of text with emoji as images, cut short with "…" if it's wider
// than max_w (for titles and bios). Returns the x after it, and whether it was cut.
draw_text_line :: proc(a: ^Assets, font: Font, size, x, y: f32, text: string, color: Color, max_w: f32) -> (end: f32, cut: bool) {
	r := &a.renderer
	segments := emoji_segments(a, text)
	emoji_h := size * r.text_scale * 1.25
	lh := line_height(r, font, size)
	total: f32
	for s in segments {
		total += width(r, font, size, emoji_h, s)
	}
	ellipsis :: "…"
	room := max_w if total <= max_w else max_w - text_width(r, font, size, ellipsis)

	pen := x
	for s in segments {
		w := width(r, font, size, emoji_h, s)
		if pen + w - x > room {
			// Text is cut between characters; an emoji that doesn't fit is left out.
			if s.image == "" {
				fitted := fit_prefix(r, font, size, s.text, room - (pen - x))
				pen = draw_text(r, font, size, pen, y, fitted, color)
			}
			cut = true
			break
		}
		if s.image == "" {
			draw_text(r, font, size, pen, y, s.text, color)
		} else {
			image := image_get(&a.images, &a.jobs, emoji_url(s.image), 1)
			switch image.state {
			case .Ready:
				texture, _ := image_frame(image, a.now_ms)
				draw_image(r, texture, {pen, y + (lh - emoji_h) / 2, emoji_h, emoji_h})
			case .Failed:
				draw_text(r, font, size, pen, y, s.text, color)
			case .Loading:
			// Its space stays empty until it arrives.
			}
		}
		pen += w
	}
	if cut {
		pen = draw_text(r, font, size, pen, y, ellipsis, color)
	}
	return pen, cut
}

// How wide draw_text_line draws `text`, emoji included, when it isn't cut.
text_line_width :: proc(a: ^Assets, font: Font, size: f32, text: string) -> f32 {
	r := &a.renderer
	emoji_h := size * r.text_scale * 1.25
	total: f32
	for s in emoji_segments(a, text) {
		total += width(r, font, size, emoji_h, s)
	}
	return total
}

// Text with its emoji split out: runs of plain text, and single emoji with the
// image to draw for each.
@(private = "file")
Segment :: struct {
	text:  string,
	image: string,
}

@(private = "file")
emoji_segments :: proc(a: ^Assets, text: string) -> []Segment {
	segments := make([dynamic]Segment, context.temp_allocator)
	for pos := 0; pos < len(text); {
		start, end, image, found := find_emoji(&a.emoji, text, pos)
		if !found {
			append(&segments, Segment{text = text[pos:]})
			break
		}
		if start > pos {
			append(&segments, Segment{text = text[pos:start]})
		}
		append(&segments, Segment{text = text[start:end], image = image})
		pos = end
	}
	return segments[:]
}

@(private = "file")
width :: proc(r: ^Renderer, font: Font, size, emoji_h: f32, s: Segment) -> f32 {
	return emoji_h if s.image != "" else text_width(r, font, size, s.text)
}

// The longest start of `text` no wider than max_w, on a character boundary.
@(private = "file")
fit_prefix :: proc(r: ^Renderer, font: Font, size: f32, text: string, max_w: f32) -> string {
	end := 0
	for i := 0; i < len(text); {
		_, n := utf8.decode_rune_in_string(text[i:])
		if text_width(r, font, size, text[:i + n]) > max_w {
			break
		}
		i += n
		end = i
	}
	return strings.trim_right_space(text[:end])
}
