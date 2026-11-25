package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// What's pinned, predicted and polled on the channel being watched, shown above
// its chat: a pinned message, a prediction with how the points are split, and a
// poll as Twitch shows it, a bar for each choice with its share of the votes. Twitch's chat doesn't carry them, so they're
// asked for every CHAT_BANNER_CHECK_MS while a live stream plays. The poll is
// asked for on its own (on the channel's user, where Twitch keeps it), so that if
// Twitch changes it, only the poll goes. A finished poll stays about a minute
// with its result, as Twitch keeps it, then goes.

CHAT_BANNER_CHECK_MS :: 20_000
// A poll choice's bar, the part of it its votes fill, and the leading choice's
// once the poll has ended.
POLL_TRACK :: Color{0xff, 0xff, 0xff, 14}
POLL_FILL :: Color{0x91, 0x47, 0xff, 85}
POLL_WINNER_FILL :: Color{0x91, 0x47, 0xff, 160}
// Under the mouse, a part that can be expanded or minimized.
CHAT_BANNER_HOVER :: Color{0xff, 0xff, 0xff, 10}

Banner_Item :: enum {
	Pinned,
	Prediction,
	Poll,
}

Poll_Choice :: struct {
	// Owned.
	title: string,
	votes: int,
}

// A poll, as viewers see it. Owned.
Poll :: struct {
	title:        string,
	choices:      [dynamic]Poll_Choice,
	ended:        bool,
	// How long it had left when asked.
	remaining_ms: int,
}

poll_destroy :: proc(p: ^Poll) {
	delete(p.title)
	for c in p.choices {
		delete(c.title)
	}
	delete(p.choices)
	p^ = {}
}

Chat_Banner :: struct {
	// The lines shown ("" for none). Owned.
	pinned:     string,
	prediction: string,
	// The poll, with no choices when there's none, and when it ends (Assets.now_ms).
	poll:       Poll,
	poll_ends_at: int,
	// Minimized to a line each by clicking them, until the stream is left.
	collapsed:  [Banner_Item]bool,
	// Set while drawing: where each is (zero size when not shown or there's
	// nothing more to show of it), for clicking.
	item_rects: [Banner_Item]Rect,
	// How many are in the chat (for Chat_Rules.chatter_count); 0 until known.
	chatters:   int,
	next_at:    int,
	pending:    bool,
}

chat_banner_destroy :: proc(b: ^Chat_Banner) {
	delete(b.pinned)
	delete(b.prediction)
	poll_destroy(&b.poll)
	b^ = {}
}

// Asks what's pinned and predicted when it's time. Returns ms until it's next
// due, for the main loop's wait.
chat_banner_tick :: proc(app: ^App) -> (wait_ms: int) {
	w := &app.watch
	b := &w.banner
	if app.screen != .Watch || w.playing_vod || w.status != .Playing || w.channel == "" || b.pending {
		return -1
	}
	now := app.assets.now_ms
	if now < b.next_at {
		return b.next_at - now
	}
	b.pending = true
	b.next_at = now + CHAT_BANNER_CHECK_MS
	jobs_add(
		&app.assets.jobs,
		run_chat_banner_job,
		Chat_Banner_Job{client_id = strings.clone(app.client_id), login = strings.clone(w.channel), session = app.session, ask_poll = !app.layout.chat.poll_off},
	)
	return CHAT_BANNER_CHECK_MS
}

Chat_Banner_Job :: struct {
	client_id, login: string,
	session:          int,
	// Polls are shown (Chat_Rules.poll_off): not asked for otherwise.
	ask_poll:         bool,
	ok:               bool,
	chatters:         int,
	// The lines found. Owned.
	pinned:           string,
	prediction:       string,
	// The poll, if asking for it worked (`poll_ok`).
	poll:             Poll,
	poll_ok:          bool,
}

destroy_chat_banner_job :: proc(p: ^Chat_Banner_Job) {
	delete(p.client_id)
	delete(p.login)
	delete(p.pinned)
	delete(p.prediction)
	poll_destroy(&p.poll)
}

@(private = "file")
run_chat_banner_job :: proc(job: ^Job) {
	p := &job.payload.(Chat_Banner_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["login"] = p.login
	if !p.ask_poll {
		p.poll_ok = true
	} else if body, err := gql_post(p.client_id, "", "query($login: String!) { user(login: $login) { viewablePoll { title status remainingDurationMilliseconds choices { title votes { total } } } } }", variables); err == .None {
		p.poll, p.poll_ok = parse_poll_response(body)
	}
	body, err := gql_post(
		p.client_id,
		"",
		"query($login: String!) { channel(name: $login) { chatters { count } pinnedChatMessages(first: 1) { edges { node { pinnedMessage { content { text } sender { displayName } } } } } activePredictionEvents { title status outcomes { title totalPoints } } } }",
		variables,
	)
	if err != .None {
		return
	}
	pinned, prediction, chatters, ok := parse_chat_banner_response(body)
	if !ok {
		return
	}
	p.ok = true
	p.chatters = chatters
	p.pinned = strings.clone(pinned)
	p.prediction = strings.clone(prediction)
}

// The pinned message and the prediction as their lines ("" for none), and how
// many are in the chat. Allocated with the temp allocator.
parse_chat_banner_response :: proc(body: []byte) -> (pinned, prediction: string, chatters: int, ok: bool) {
	r: struct {
		data: struct {
			channel: Maybe(struct {
				chatters:               Maybe(struct {
					count: int,
				}),
				pinnedChatMessages:     Maybe(struct {
					edges: []struct {
						node: struct {
							pinnedMessage: Maybe(struct {
								content: struct {
									text: string,
								},
								sender:  Maybe(struct {
									displayName: string,
								}),
							}),
						},
					},
				}),
				activePredictionEvents: []struct {
					title:    string,
					status:   string,
					outcomes: []struct {
						title:       string,
						totalPoints: int,
					},
				},
			}),
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return "", "", 0, false
	}
	channel, has_channel := r.data.channel.?
	if !has_channel {
		return "", "", 0, true
	}
	if c, has_count := channel.chatters.?; has_count {
		chatters = c.count
	}
	if pins, has_pins := channel.pinnedChatMessages.?; has_pins && len(pins.edges) > 0 {
		if m, has_message := pins.edges[0].node.pinnedMessage.?; has_message && m.content.text != "" {
			sender := m.sender.? or_else {}
			pinned = fmt.tprintf("Pinned · %s: %s", sender.displayName, m.content.text) if sender.displayName != "" else fmt.tprintf("Pinned · %s", m.content.text)
		}
	}
	for e in channel.activePredictionEvents {
		// Resolved or canceled ones may linger in the list a moment.
		if e.status != "ACTIVE" && e.status != "LOCKED" {
			continue
		}
		total := 0
		for o in e.outcomes {
			total += o.totalPoints
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "Prediction%s · %s:", " (locked)" if e.status == "LOCKED" else "", e.title)
		for o, i in e.outcomes {
			share := 0 if total == 0 else int(f64(o.totalPoints) * 100 / f64(total) + 0.5)
			fmt.sbprintf(&b, "%s %s %d%%", " ·" if i > 0 else "", o.title, share)
		}
		prediction = strings.to_string(b)
		break
	}
	return pinned, prediction, chatters, true
}

// The poll viewers can see, with no choices when there's none (or it's archived
// or was removed). Not ok if the answer isn't one.
parse_poll_response :: proc(body: []byte) -> (poll: Poll, ok: bool) {
	r: struct {
		data: struct {
			user: Maybe(struct {
				viewablePoll: Maybe(struct {
					title:                         string,
					status:                        string,
					remainingDurationMilliseconds: int,
					choices:                       []struct {
						title: string,
						votes: struct {
							total: int,
						},
					},
				}),
			}),
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return {}, false
	}
	user, has_user := r.data.user.?
	if !has_user {
		return {}, true
	}
	found, has_poll := user.viewablePoll.?
	if !has_poll || found.status != "ACTIVE" && found.status != "COMPLETED" || len(found.choices) == 0 {
		return {}, true
	}
	poll = {
		title        = strings.clone(found.title),
		ended        = found.status == "COMPLETED",
		remaining_ms = found.remainingDurationMilliseconds,
	}
	for c in found.choices {
		append(&poll.choices, Poll_Choice{strings.clone(c.title), c.votes.total})
	}
	return poll, true
}

finish_chat_banner_job :: proc(app: ^App, p: ^Chat_Banner_Job) {
	w := &app.watch
	if p.session != app.session || app.screen != .Watch || w.channel != p.login {
		return
	}
	w.banner.pending = false
	// Kept as it was when asking failed, as the other lines are.
	if p.poll_ok {
		poll_destroy(&w.banner.poll)
		w.banner.poll, p.poll = p.poll, {}
		w.banner.poll_ends_at = app.assets.now_ms + w.banner.poll.remaining_ms
	}
	if !p.ok {
		return
	}
	delete(w.banner.pinned)
	delete(w.banner.prediction)
	w.banner.pinned, p.pinned = p.pinned, ""
	w.banner.prediction, p.prediction = p.prediction, ""
	w.banner.chatters = p.chatters
}

// How many lines the pinned message and the prediction each wrap to at most, the
// poll's title, and each of its choices; past that, the last line ends in "…".
BANNER_MAX_LINES :: 6
POLL_TITLE_MAX_LINES :: 3
POLL_CHOICE_MAX_LINES :: 2
POLL_BAR_GAP :: 4

// `text` in lines no wider than `max_w`: between words, or within a word too
// long for a line of its own (a link). At most `max_lines`, the last cut with
// "…" when there's more. Allocated with the temp allocator.
banner_wrap :: proc(a: ^Assets, font: Font, size: f32, text: string, max_w: f32, max_lines: int) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	for line in wrap_words(a, font, size, text, max_w) {
		rest := line
		// A word wider than the line, broken between characters.
		for len(rest) > 0 && text_line_width(a, font, size, rest) > max_w {
			end := 0
			for i := 0; i < len(rest); {
				_, n := utf8.decode_rune_in_string(rest[i:])
				if end > 0 && text_line_width(a, font, size, rest[:i + n]) > max_w {
					break
				}
				i += n
				end = i
			}
			append(&lines, rest[:end])
			rest = rest[end:]
		}
		if len(rest) > 0 {
			append(&lines, rest)
		}
	}
	if len(lines) > max_lines {
		// The last line shown runs on to the end of `text`, cut to fit.
		from := int(uintptr(raw_data(lines[max_lines - 1])) - uintptr(raw_data(text)))
		lines[max_lines - 1] = fit_text(&a.renderer, font, size, strings.trim_space(text[from:]), max_w)
		resize(&lines, max_lines)
	}
	return lines[:]
}

// What the banner shows at `width`, wrapped: drawn by draw_chat_banner, and
// measured with it for the chat's layout.
@(private = "file")
Banner_Layout :: struct {
	items:   [Banner_Item]Item_Layout,
	choices: [dynamic]Choice_Layout,
	status:  string,
	line_h:  f32,
	height:  f32,
}

// One of the three: its lines (the poll's title), whether it can be expanded or
// minimized, and its height with the poll's bars.
@(private = "file")
Item_Layout :: struct {
	lines:      []string,
	toggleable: bool,
	height:     f32,
}

@(private = "file")
Choice_Layout :: struct {
	lines:   []string,
	numbers: string,
	share:   f32,
	winner:  bool,
	height:  f32,
}

// Room on the right for the expand or minimize arrow.
BANNER_ARROW_W :: 18

@(private = "file")
banner_layout :: proc(app: ^App, width: f32) -> (l: Banner_Layout) {
	a := &app.assets
	r := &a.renderer
	b := &app.watch.banner
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	pad := CHAT_PADDING * scale
	text_h := line_height(r, .Regular, size)
	l.line_h = text_h + pad / 4
	w := width - 16 * scale - BANNER_ARROW_W * scale
	rules := &app.layout.chat
	for item, i in ([2]Banner_Item{.Pinned, .Prediction}) {
		text := b.pinned if i == 0 else b.prediction
		if text == "" || (rules.pinned_off if i == 0 else rules.prediction_off) {
			continue
		}
		full := banner_wrap(a, .Regular, size, text, w, BANNER_MAX_LINES)
		it := &l.items[item]
		it.toggleable = len(full) > 1
		it.lines = full
		if b.collapsed[item] && it.toggleable {
			one := make([]string, 1, context.temp_allocator)
			one[0] = fit_text(r, .Regular, size, text, w)
			it.lines = one
		}
		it.height = f32(len(it.lines)) * l.line_h
		l.height += it.height
	}
	poll := &b.poll
	if len(poll.choices) > 0 && !rules.poll_off {
		it := &l.items[.Poll]
		it.toggleable = true
		l.status = poll_status(poll, b.poll_ends_at - a.now_ms)
		if b.collapsed[.Poll] {
			// The title and how it stands, on one line.
			one := make([]string, 1, context.temp_allocator)
			one[0] = fit_text(r, .Bold, size, fmt.tprintf("Poll: %s · %s", poll.title, l.status), w)
			it.lines = one
			it.height = l.line_h
		} else {
			status_w := text_width(r, .Regular, size, l.status)
			it.lines = banner_wrap(a, .Bold, size, fmt.tprintf("Poll: %s", poll.title), w - status_w - 12 * scale, POLL_TITLE_MAX_LINES)
			it.height = f32(len(it.lines)) * l.line_h + pad / 4
			total, most := 0, 0
			for c in poll.choices {
				total += c.votes
				most = max(most, c.votes)
			}
			l.choices = make([dynamic]Choice_Layout, context.temp_allocator)
			bar_w := width - 16 * scale
			for c in poll.choices {
				share: f32 = 0 if total == 0 else f32(c.votes) / f32(total)
				winner := poll.ended && total > 0 && c.votes == most
				numbers := fmt.tprintf("%d%% (%d)", int(share * 100 + 0.5), c.votes)
				numbers_w := text_width(r, .Bold, size, numbers)
				lines := banner_wrap(a, .Bold if winner else .Regular, size, c.title, bar_w - numbers_w - 24 * scale, POLL_CHOICE_MAX_LINES)
				choice_h := f32(max(1, len(lines))) * text_h + 8 * scale
				append(&l.choices, Choice_Layout{lines, numbers, share, winner, choice_h})
				it.height += choice_h + POLL_BAR_GAP * scale
			}
		}
		l.height += it.height
	}
	if l.height > 0 {
		l.height += pad / 2
	}
	return
}

// The banner's height at `width`: the pinned message and the prediction,
// wrapped, and the poll's title and a bar per choice. 0 when there's nothing.
chat_banner_height :: proc(app: ^App, width: f32) -> f32 {
	return banner_layout(app, width).height
}

// "1:42 left", or "Ended", and how many voted. Allocated with the temp allocator.
poll_status :: proc(poll: ^Poll, left_ms: int) -> string {
	total := 0
	for c in poll.choices {
		total += c.votes
	}
	votes := fmt.tprintf("%d vote%s", total, "" if total == 1 else "s")
	switch {
	case poll.ended:
		return fmt.tprintf("Ended · %s", votes)
	case left_ms <= 0:
		return fmt.tprintf("Ending · %s", votes)
	}
	seconds := (left_ms + 999) / 1000
	return fmt.tprintf("%d:%02d left · %s", seconds / 60, seconds % 60, votes)
}

// Draws the banner in `rect`, as chat_banner_height measured it, noting where
// each part is for chat_banner_click.
draw_chat_banner :: proc(app: ^App, rect: Rect) {
	a := &app.assets
	r := &a.renderer
	b := &app.watch.banner
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	pad := CHAT_PADDING * scale
	text_h := line_height(r, .Regular, size)
	l := banner_layout(app, rect.w)
	b.item_rects = {}
	draw_rect(r, rect, CHAT_HEADER)
	clip_begin(r, rect)
	defer clip_end(r)
	x := rect.x + 8 * scale
	w := rect.w - 16 * scale - BANNER_ARROW_W * scale
	y := rect.y + pad / 4
	for item in Banner_Item {
		it := l.items[item]
		if it.height == 0 {
			continue
		}
		area := Rect{rect.x, y, rect.w, it.height}
		if it.toggleable {
			b.item_rects[item] = area
			hovered := in_rect(area, app.mouse.x, app.mouse.y)
			if hovered {
				draw_rect(r, area, CHAT_BANNER_HOVER)
			}
			// A chevron on the first line's right, drawn (Noto Sans has no arrows):
			// pointing down to minimize, right to expand.
			arrow := text_h * 0.4
			stroke := max(1.5, 2 * scale * r.text_scale)
			color := CHAT_TEXT if hovered else CHAT_SYSTEM_TEXT
			cx := rect.x + rect.w - 8 * scale - arrow * 0.75
			cy := y + text_h / 2
			if b.collapsed[item] {
				draw_line(r, cx - arrow / 4, cy - arrow / 2, cx + arrow / 4, cy, stroke, color)
				draw_line(r, cx + arrow / 4, cy, cx - arrow / 4, cy + arrow / 2, stroke, color)
			} else {
				draw_line(r, cx - arrow / 2, cy - arrow / 4, cx, cy + arrow / 4, stroke, color)
				draw_line(r, cx, cy + arrow / 4, cx + arrow / 2, cy - arrow / 4, stroke, color)
			}
		}
		font: Font = .Bold if item == .Poll else .Regular
		line_w := w
		if item == .Poll && !b.collapsed[.Poll] {
			// The time left and votes on the right of the title.
			status_w := text_width(r, .Regular, size, l.status)
			draw_text(r, .Regular, size, x + w - status_w, y, l.status, CHAT_SYSTEM_TEXT)
			line_w = w - status_w - 12 * scale
		}
		ly := y
		for line in it.lines {
			draw_text_line(a, font, size, x, ly, line, CHAT_TEXT, line_w)
			ly += l.line_h
		}
		if item == .Poll && !b.collapsed[.Poll] {
			cy := ly + pad / 4
			for c in l.choices {
				bar := Rect{x, cy, rect.w - 16 * scale, c.height}
				draw_rect(r, bar, POLL_TRACK)
				if c.share > 0 {
					draw_rect(r, {bar.x, bar.y, bar.w * c.share, bar.h}, POLL_WINNER_FILL if c.winner else POLL_FILL)
				}
				numbers_w := text_width(r, .Bold, size, c.numbers)
				draw_text(r, .Bold, size, bar.x + bar.w - 8 * scale - numbers_w, bar.y + (bar.h - text_h) / 2, c.numbers, CHAT_TEXT)
				choice_font: Font = .Bold if c.winner else .Regular
				ty := bar.y + 4 * scale
				for line in c.lines {
					draw_text_line(a, choice_font, size, bar.x + 8 * scale, ty, line, CHAT_TEXT, bar.w - numbers_w - 24 * scale)
					ty += text_h
				}
				cy += c.height + POLL_BAR_GAP * scale
			}
		}
		if item == .Poll {
			// The countdown moves on each second, minimized too.
			left_ms := b.poll_ends_at - a.now_ms
			if !b.poll.ended && left_ms > 0 {
				next := left_ms % 1000 + 1
				if a.next_frame_ms < 0 || next < a.next_frame_ms {
					a.next_frame_ms = next
				}
			}
		}
		y += it.height
	}
}

// A click on the banner: expands or minimizes the part clicked. Returns whether
// (x, y) was on one.
chat_banner_click :: proc(app: ^App, x, y: f32) -> bool {
	b := &app.watch.banner
	for rect, item in b.item_rects {
		if rect.w > 0 && in_rect(rect, x, y) {
			b.collapsed[item] = !b.collapsed[item]
			return true
		}
	}
	return false
}
