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
// Around the choices the user voted for.
POLL_MINE :: Color{0xff, 0xff, 0xff, 150}
// A prediction's outcomes, as Twitch colours them.
PREDICTION_BLUE :: Color{0x38, 0x7a, 0xff, 255}
PREDICTION_PINK :: Color{0xf5, 0x00, 0x9b, 255}
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
	// Owned.
	id:    string,
	// Voted for by the user.
	mine:  bool,
}

// A poll, as viewers see it. Owned.
Poll :: struct {
	id, title:    string,
	choices:      [dynamic]Poll_Choice,
	ended:        bool,
	// Each viewer may vote for more than one choice.
	multichoice:  bool,
	// How long it had left when asked.
	remaining_ms: int,
}

poll_destroy :: proc(p: ^Poll) {
	delete(p.id)
	delete(p.title)
	for c in p.choices {
		delete(c.title)
		delete(c.id)
	}
	delete(p.choices)
	p^ = {}
}

Prediction_Outcome :: struct {
	// Owned.
	id, title: string,
	// Its share of the points, in percent.
	share: int,
	pink:  bool,
}

// A running prediction, as viewers see it. Owned.
Prediction :: struct {
	id, title: string,
	locked:    bool,
	outcomes:  [dynamic]Prediction_Outcome,
	// What the signed-in user bet, on which outcome (an index into `outcomes`);
	// 0 points for nothing.
	mine:      int,
	mine_on:   int,
}

prediction_destroy :: proc(p: ^Prediction) {
	delete(p.id)
	delete(p.title)
	for o in p.outcomes {
		delete(o.id)
		delete(o.title)
	}
	delete(p.outcomes)
	p^ = {}
}

// The prediction's line, "Prediction (locked) · Title: Yes 75% · No 25%", with
// each outcome in its colour. Allocated with the temp allocator.
prediction_runs :: proc(p: ^Prediction) -> []Banner_Run {
	runs := make([dynamic]Banner_Run, context.temp_allocator)
	append(&runs, Banner_Run{fmt.tprintf("Prediction%s · %s:", " (locked)" if p.locked else "", p.title), .Regular, CHAT_TEXT})
	for o, i in p.outcomes {
		if i > 0 {
			append(&runs, Banner_Run{" ·", .Regular, CHAT_SYSTEM_TEXT})
		}
		append(&runs, Banner_Run{fmt.tprintf(" %s %d%%", o.title, o.share), .Bold, PREDICTION_PINK if o.pink else PREDICTION_BLUE})
	}
	return runs[:]
}

Chat_Banner :: struct {
	// The pinned message, drawn as the chat draws one (no fragments for none),
	// and the prediction (no outcomes for none). Owned.
	pinned:     Chat_Message,
	prediction: Prediction,
	// The poll, with no choices when there's none, and when it ends (Assets.now_ms).
	poll:       Poll,
	poll_ends_at: int,
	// Minimized to a line each by clicking them, until the stream is left.
	collapsed:  [Banner_Item]bool,
	// Betting on the prediction (predictions.odin), and voting in the poll
	// (poll_votes.odin).
	bet:        Prediction_Bet,
	vote:       Poll_Vote,
	// Set while drawing: where each is (zero size when not shown or there's
	// nothing more to show of it), for clicking.
	item_rects: [Banner_Item]Rect,
	// Set while drawing: where the pinned message's name, emotes and links are.
	hits:       Chat_View,
	// How many are in the chat (for Chat_Rules.chatter_count); 0 until known.
	chatters:   int,
	next_at:    int,
	pending:    bool,
}

chat_banner_destroy :: proc(b: ^Chat_Banner) {
	destroy_chat_message(b.pinned)
	prediction_destroy(&b.prediction)
	poll_destroy(&b.poll)
	chat_view_destroy(&b.hits)
	delete(b.bet.error)
	delete(b.bet.hits)
	delete(b.vote.error)
	b^ = {}
}

// Looks for third-party emotes and emoji in the pinned message again, as the
// chat does when a set of them loads, and lays it out again (badges loading).
chat_banner_refresh_emotes :: proc(app: ^App) {
	m := &app.watch.banner.pinned
	if len(m.fragments) > 0 {
		apply_third_party_emotes(m, watched_emotes(app), &app.assets.emotes)
		apply_emoji(m, &app.assets.emoji)
	}
	m.layout.height = 0
}

// The watched channel's own emotes and badges, from its split, or nil.
@(private = "file")
watched_emotes :: proc(app: ^App) -> ^Emotes {
	for pane in app.watch.panes {
		if pane.channel != "" && pane.channel == app.watch.channel {
			return &pane.emotes
		}
	}
	return nil
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
	job := Chat_Banner_Job {
		client_id = strings.clone(app.client_id),
		login     = strings.clone(w.channel),
		session   = app.session,
		ask_poll  = !app.layout.chat.poll_off,
	}
	// Signed in, the prediction and poll come with what the user bet and voted.
	if app.signed_in {
		job.token = strings.clone(app.auth.access_token)
	}
	jobs_add(&app.assets.jobs, run_chat_banner_job, job)
	return CHAT_BANNER_CHECK_MS
}

Chat_Banner_Job :: struct {
	// The token is "" signed out.
	client_id, login, token: string,
	session:          int,
	// Polls are shown (Chat_Rules.poll_off): not asked for otherwise.
	ask_poll:         bool,
	ok:               bool,
	chatters:         int,
	// What was found. Owned.
	pinned:           Chat_Message,
	prediction:       Prediction,
	// The poll, if asking for it worked (`poll_ok`).
	poll:             Poll,
	poll_ok:          bool,
}

destroy_chat_banner_job :: proc(p: ^Chat_Banner_Job) {
	delete(p.client_id)
	delete(p.login)
	delete(p.token)
	destroy_chat_message(p.pinned)
	prediction_destroy(&p.prediction)
	poll_destroy(&p.poll)
}

@(private = "file")
run_chat_banner_job :: proc(job: ^Job) {
	p := &job.payload.(Chat_Banner_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["login"] = p.login
	if !p.ask_poll {
		p.poll_ok = true
	} else if body, err := gql_post(
		p.client_id,
		p.token,
		"query($login: String!) { user(login: $login) { viewablePoll { id title status remainingDurationMilliseconds settings { multichoice { isEnabled } } choices { id title votes { total } } self { voter { choices { pollChoice { id } } } } } } }",
		variables,
	); err == .None {
		p.poll, p.poll_ok = parse_poll_response(body)
	}
	body, err := gql_post(
		p.client_id,
		p.token,
		"query($login: String!) { channel(name: $login) { chatters { count } pinnedChatMessages(first: 1) { edges { node { pinnedMessage { content { text fragments { text content { __typename ... on Emote { id } } } } sender { login displayName chatColor displayBadges { setID version } } } } } } activePredictionEvents { id title status outcomes { id title totalPoints color } self { prediction { points outcome { id } } } } } }",
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
	p.pinned = pinned
	p.prediction = prediction
}

// The pinned message as a chat message (no fragments for none), the prediction
// (no outcomes for none), both owned, and how many are in the chat.
parse_chat_banner_response :: proc(body: []byte) -> (pinned: Chat_Message, prediction: Prediction, chatters: int, ok: bool) {
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
									text:      string,
									fragments: []struct {
										text:    string,
										// An emote, a mention, or nil for text.
										content: Maybe(struct {
											typename: string `json:"__typename"`,
											id:       string,
										}),
									},
								},
								sender:  Maybe(struct {
									login:         string,
									displayName:   string,
									chatColor:     string,
									displayBadges: []struct {
										setID, version: string,
									},
								}),
							}),
						},
					},
				}),
				activePredictionEvents: []struct {
					id:       string,
					title:    string,
					status:   string,
					// Signed in: what the user bet, if they did.
					self:     Maybe(struct {
						prediction: Maybe(struct {
							points:  int,
							outcome: Maybe(struct {
								id: string,
							}),
						}),
					}),
					outcomes: []struct {
						id:          string,
						title:       string,
						totalPoints: int,
						// "BLUE" or "PINK".
						color:       string,
					},
				},
			}),
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return {}, {}, 0, false
	}
	channel, has_channel := r.data.channel.?
	if !has_channel {
		return {}, {}, 0, true
	}
	if c, has_count := channel.chatters.?; has_count {
		chatters = c.count
	}
	if pins, has_pins := channel.pinnedChatMessages.?; has_pins && len(pins.edges) > 0 {
		if m, has_message := pins.edges[0].node.pinnedMessage.?; has_message && m.content.text != "" {
			pinned.label = strings.clone("Pinned")
			if sender, has_sender := m.sender.?; has_sender && sender.login != "" {
				// As the chat names people: their display name, and their login too
				// when it's written in another script.
				name := sender.displayName if sender.displayName != "" else sender.login
				if strings.to_lower(name, context.temp_allocator) != sender.login {
					name = strings.concatenate({name, " (", sender.login, ")"}, context.temp_allocator)
				}
				color, color_ok := parse_hex_color(sender.chatColor)
				if !color_ok {
					color = default_name_color(sender.login)
				}
				pinned.kind = .Chat
				pinned.name = strings.clone(name)
				pinned.login = strings.clone(sender.login)
				pinned.color = readable_on_dark(color)
				for b in sender.displayBadges {
					if b.setID != "" {
						append(&pinned.badges, fmt.aprintf("%s/%s", b.setID, b.version))
					}
				}
			} else {
				// No one to name: just the text, as a /me shows it.
				pinned.kind = .Action
				pinned.color = CHAT_TEXT
			}
			for f in m.content.fragments {
				if c, has_content := f.content.?; has_content && c.typename == "Emote" && c.id != "" {
					append(
						&pinned.fragments,
						Fragment {
							kind = .Emote,
							text = strings.clone(strings.trim_space(f.text)),
							url_1x = fmt.aprintf(TWITCH_EMOTE_URL, c.id, "1.0"),
							url_2x = fmt.aprintf(TWITCH_EMOTE_URL, c.id, "2.0"),
						},
					)
				} else if f.text != "" {
					append(&pinned.fragments, Fragment{kind = .Text, text = strings.clone(f.text)})
				}
			}
			if len(pinned.fragments) == 0 {
				append(&pinned.fragments, Fragment{kind = .Text, text = strings.clone(m.content.text)})
			}
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
		prediction.id = strings.clone(e.id)
		prediction.title = strings.clone(e.title)
		prediction.locked = e.status == "LOCKED"
		mine: struct {
			points:  int,
			outcome: string,
		}
		if self, signed_in := e.self.?; signed_in {
			if bet, has_bet := self.prediction.?; has_bet {
				on := bet.outcome.? or_else {}
				mine = {bet.points, on.id}
			}
		}
		for o, i in e.outcomes {
			share := 0 if total == 0 else int(f64(o.totalPoints) * 100 / f64(total) + 0.5)
			// Without its colour, the second of two is pink, as Twitch has it.
			pink := o.color == "PINK" || o.color == "" && len(e.outcomes) == 2 && i == 1
			append(&prediction.outcomes, Prediction_Outcome{strings.clone(o.id), strings.clone(o.title), share, pink})
			if mine.points > 0 && o.id == mine.outcome {
				prediction.mine, prediction.mine_on = mine.points, i
			}
		}
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
					id:                            string,
					title:                         string,
					status:                        string,
					remainingDurationMilliseconds: int,
					settings:                      struct {
						multichoice: struct {
							isEnabled: bool,
						},
					},
					choices:                       []struct {
						id:    string,
						title: string,
						votes: struct {
							total: int,
						},
					},
					// Signed in only: what the user voted for.
					self:                          Maybe(struct {
						voter: Maybe(struct {
							choices: []struct {
								pollChoice: struct {
									id: string,
								},
							},
						}),
					}),
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
		id           = strings.clone(found.id),
		title        = strings.clone(found.title),
		ended        = found.status == "COMPLETED",
		multichoice  = found.settings.multichoice.isEnabled,
		remaining_ms = found.remainingDurationMilliseconds,
	}
	voted: []struct {
		pollChoice: struct {
			id: string,
		},
	}
	if self, has_self := found.self.?; has_self {
		if voter, has_voter := self.voter.?; has_voter {
			voted = voter.choices
		}
	}
	for c in found.choices {
		mine := false
		for v in voted {
			mine ||= c.id != "" && v.pollChoice.id == c.id
		}
		append(&poll.choices, Poll_Choice{title = strings.clone(c.title), votes = c.votes.total, id = strings.clone(c.id), mine = mine})
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
		// Another poll: why voting in the last one failed goes.
		if p.poll.id != w.banner.poll.id {
			delete(w.banner.vote.error)
			w.banner.vote.error = ""
		}
		poll_destroy(&w.banner.poll)
		w.banner.poll, p.poll = p.poll, {}
		w.banner.poll_ends_at = app.assets.now_ms + w.banner.poll.remaining_ms
	}
	if !p.ok {
		return
	}
	destroy_chat_message(w.banner.pinned)
	// Another prediction: what was being chosen for the last one goes.
	if p.prediction.id != w.banner.prediction.id {
		prediction_bet_reset(&w.banner.bet)
	}
	prediction_destroy(&w.banner.prediction)
	w.banner.pinned, p.pinned = p.pinned, {}
	w.banner.prediction, p.prediction = p.prediction, {}
	w.banner.chatters = p.chatters
	chat_banner_refresh_emotes(app)
}

// How many lines the pinned message (under its "Pinned" line) and the prediction
// each wrap to at most, the poll's title, and each of its choices; past that, the
// prediction's last line ends in "…", and the pinned message is cut off.
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

// A run of text in one font and colour, for banner_wrap_runs.
Banner_Run :: struct {
	text:  string,
	font:  Font,
	color: Color,
}

// A word placed by banner_wrap_runs: on which line, and how far along it.
@(private = "file")
Placed_Word :: struct {
	using run: Banner_Run,
	x:         f32,
	line:      int,
}

// `runs` in lines no wider than `max_w`, broken between words, each word in its
// run's font and colour. Runs join without a space unless one starts with one.
// At most `max_lines`, the last ending in "…" when there's more. Returns the
// words and how many lines they take. Allocated with the temp allocator.
@(private = "file")
banner_wrap_runs :: proc(a: ^Assets, size: f32, runs: []Banner_Run, max_w: f32, max_lines: int) -> (words: []Placed_Word, lines: int) {
	r := &a.renderer
	out := make([dynamic]Placed_Word, context.temp_allocator)
	x: f32
	line := 0
	cut := false
	runs_loop: for run in runs {
		rest := run.text
		glued := len(rest) > 0 && rest[0] != ' '
		for word in strings.fields_iterator(&rest) {
			w := text_line_width(a, run.font, size, word)
			gap: f32 = 0 if x == 0 || glued else text_width(r, run.font, size, " ")
			glued = false
			if x > 0 && x + gap + w > max_w {
				if line + 1 == max_lines {
					cut = true
					break runs_loop
				}
				line += 1
				x, gap = 0, 0
			}
			append(&out, Placed_Word{{word, run.font, run.color}, x + gap, line})
			x += gap + w
		}
	}
	if cut {
		// Words come off the last line until "…" fits after it.
		ellipsis :: "…"
		end: f32
		last := Banner_Run{ellipsis, .Regular, CHAT_TEXT}
		for len(out) > 0 && out[len(out) - 1].line == line {
			word := out[len(out) - 1]
			end = word.x + text_line_width(a, word.font, size, word.text)
			if end + text_width(r, word.font, size, ellipsis) <= max_w {
				last.font, last.color = word.font, word.color
				break
			}
			pop(&out)
			end = 0
		}
		append(&out, Placed_Word{last, end, line})
	}
	return out[:], line + 1
}

// What the banner shows at `width`, wrapped: drawn by draw_chat_banner, and
// measured with it for the chat's layout.
@(private = "file")
Banner_Layout :: struct {
	items:   [Banner_Item]Item_Layout,
	// What's under the prediction to bet with.
	bet:     Bet_Row,
	choices: [dynamic]Choice_Layout,
	status:  string,
	line_h:  f32,
	height:  f32,
}

// One of the three: its lines (the poll's title; the pinned message is laid out
// as a chat message instead), whether it can be expanded or minimized, and its
// height with the poll's bars.
@(private = "file")
Item_Layout :: struct {
	lines:      []string,
	// The prediction's words, in their colours.
	words:      []Placed_Word,
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
banner_layout :: proc(app: ^App, emotes: ^Emotes, width: f32) -> (l: Banner_Layout) {
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
	if len(b.pinned.fragments) > 0 && !rules.pinned_off {
		// "Pinned" and the message, as many lines of it as fit; minimized, its first.
		it := &l.items[.Pinned]
		height, lines := message_lines_height(message_layout(a, emotes, &b.pinned, scale, w), 1 + BANNER_MAX_LINES)
		it.toggleable = lines > 2
		if b.collapsed[.Pinned] && it.toggleable {
			height, _ = message_lines_height(&b.pinned.layout, 2)
		}
		it.height = height + pad / 4
		l.height += it.height
	}
	if len(b.prediction.outcomes) > 0 && !rules.prediction_off {
		runs := prediction_runs(&b.prediction)
		it := &l.items[.Prediction]
		words, lines := banner_wrap_runs(a, size, runs, w, BANNER_MAX_LINES)
		// Under it, the outcomes to bet on, or what was bet: hidden minimized.
		l.bet = bet_row(app)
		it.toggleable = lines > 1 || l.bet != .None
		if b.collapsed[.Prediction] && it.toggleable {
			words, lines = banner_wrap_runs(a, size, runs, w, 1)
			l.bet = .None
		}
		it.words = words
		it.height = f32(lines) * l.line_h
		if l.bet != .None {
			it.height += bet_row_height(r, size, scale)
		}
		l.height += it.height
	}
	poll := &b.poll
	if len(poll.choices) > 0 && !rules.poll_off {
		it := &l.items[.Poll]
		it.toggleable = true
		l.status = poll_vote_status(&b.vote)
		if l.status == "" {
			l.status = poll_status(poll, b.poll_ends_at - a.now_ms)
		}
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
chat_banner_height :: proc(app: ^App, emotes: ^Emotes, width: f32) -> f32 {
	return banner_layout(app, emotes, width).height
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

// Draws the banner in `rect`, as chat_banner_height measured it with the
// channel's `emotes`, noting where each part is for chat_banner_click, and the
// pinned message's name, emotes and links in `hits`.
draw_chat_banner :: proc(app: ^App, emotes: ^Emotes, rect: Rect) {
	a := &app.assets
	r := &a.renderer
	b := &app.watch.banner
	scale := app.scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	pad := CHAT_PADDING * scale
	text_h := line_height(r, .Regular, size)
	l := banner_layout(app, emotes, rect.w)
	b.item_rects = {}
	clear(&b.hits.name_hits)
	clear(&b.hits.image_hits)
	clear(&b.hits.message_hits)
	clear(&b.hits.link_hits)
	clear(&b.hits.reply_hits)
	b.hits.emotes = emotes
	b.hits.visible = {}
	clear(&b.bet.hits)
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
		if item == .Pinned {
			// Cut off below the lines shown, which are all that can be clicked.
			shown := Rect{rect.x, y, rect.w, it.height}
			b.hits.visible = shown
			clip_begin(r, shown)
			draw_message(a, &b.hits, &b.pinned, &b.pinned.layout, x, y + pad / 8)
			clip_begin(r, rect)
			y += it.height
			continue
		}
		if item == .Prediction {
			ly := y
			for word in it.words {
				draw_text_line(a, word.font, size, x + word.x, y + f32(word.line) * l.line_h, word.text, word.color, w - word.x)
				ly = max(ly, y + f32(word.line + 1) * l.line_h)
			}
			if l.bet != .None {
				draw_bet_row(app, l.bet, x, ly, rect.w - 16 * scale, size)
			}
			y += it.height
			continue
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
			for c, i in l.choices {
				bar := Rect{x, cy, rect.w - 16 * scale, c.height}
				draw_rect(r, bar, POLL_TRACK)
				if c.share > 0 {
					draw_rect(r, {bar.x, bar.y, bar.w * c.share, bar.h}, POLL_WINNER_FILL if c.winner else POLL_FILL)
				}
				// A choice to vote for is a button; one voted for is outlined.
				if poll_votable(app, i) {
					if in_rect(bar, app.mouse.x, app.mouse.y) {
						draw_rect(r, bar, BET_BUTTON)
					}
					append(&b.bet.hits, Bet_Hit{bar, .Vote, i})
				}
				if b.poll.choices[i].mine {
					edge := max(1, scale)
					draw_rect(r, {bar.x, bar.y, bar.w, edge}, POLL_MINE)
					draw_rect(r, {bar.x, bar.y + bar.h - edge, bar.w, edge}, POLL_MINE)
					draw_rect(r, {bar.x, bar.y, edge, bar.h}, POLL_MINE)
					draw_rect(r, {bar.x + bar.w - edge, bar.y, edge, bar.h}, POLL_MINE)
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
	if bet_click(app, x, y) {
		return true
	}
	for rect, item in b.item_rects {
		if rect.w > 0 && in_rect(rect, x, y) {
			b.collapsed[item] = !b.collapsed[item]
			return true
		}
	}
	return false
}
