package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"

// Betting channel points on the watched channel's prediction, from under it in
// the chat banner (chat_banner.odin): a button for each outcome, then a few
// amounts for the one picked, then what was bet. Only signed in, and only while
// the prediction is open.

// The most Twitch takes from one person on one prediction.
PREDICTION_MAX_POINTS :: 250_000
@(rodata)
BET_AMOUNTS := [?]int{10, 100, 1_000, 10_000}
// A button under the prediction, and one under the mouse.
BET_BUTTON :: Color{0xff, 0xff, 0xff, 24}
BET_BUTTON_HOVER :: Color{0xff, 0xff, 0xff, 48}
BET_GAP :: 6

// What's being chosen, sent, or went wrong for the prediction shown.
Prediction_Bet :: struct {
	// The outcome picked (an index into Prediction.outcomes) + 1; 0 for none.
	choice:  int,
	sending: bool,
	// Why the last bet didn't go through ("" if it did). Owned.
	error:   string,
	// Set while drawing: where the buttons are.
	hits:    [dynamic]Bet_Hit,
}

Bet_Action :: enum {
	Outcome,
	Amount,
	Cancel,
	// A poll choice's bar (poll_votes.odin).
	Vote,
}

// A button: picks outcome `value`, bets `value` points, cancels, or votes for
// poll choice `value`.
Bet_Hit :: struct {
	rect:   Rect,
	action: Bet_Action,
	value:  int,
}

// What the row under the prediction shows.
Bet_Row :: enum {
	None,
	// A button for each outcome.
	Outcomes,
	// Amounts to bet on the outcome picked.
	Amounts,
	Sending,
	// What the user bet.
	Mine,
}

prediction_bet_reset :: proc(bet: ^Prediction_Bet) {
	bet.choice = 0
	delete(bet.error)
	bet.error = ""
}

bet_row :: proc(app: ^App) -> Bet_Row {
	b := &app.watch.banner
	p := &b.prediction
	switch {
	case b.bet.sending:
		return .Sending
	case p.mine > 0:
		return .Mine
	case !app.signed_in || p.locked || p.id == "":
		return .None
	case b.bet.choice > 0 && b.bet.choice <= len(p.outcomes):
		return .Amounts
	}
	return .Outcomes
}

bet_row_height :: proc(r: ^Renderer, size, scale: f32) -> f32 {
	return line_height(r, .Bold, size) + 8 * scale + CHAT_PADDING * scale / 4
}

// The amounts offered: those the balance covers (all of them while it isn't
// known), and everything left, up to what one person may bet having bet `spent`.
// Allocated with the temp allocator.
bet_amounts :: proc(balance: Maybe(int), spent := 0) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	room := PREDICTION_MAX_POINTS - spent
	have, known := balance.?
	top := min(have, room) if known else room
	for amount in BET_AMOUNTS {
		if amount <= top {
			append(&out, amount)
		}
	}
	if known && top > 0 && (len(out) == 0 || out[len(out) - 1] != top) {
		append(&out, top)
	}
	return out[:]
}

// "not enough points" for Twitch's NOT_ENOUGH_POINTS. Allocated with the temp
// allocator.
bet_error_text :: proc(code: string) -> string {
	text, _ := strings.replace_all(strings.to_lower(code, context.temp_allocator), "_", " ", context.temp_allocator)
	return text
}

// Draws the row under the prediction, its top left at (x, y), noting where its
// buttons are.
draw_bet_row :: proc(app: ^App, row: Bet_Row, x, y, w, size: f32) {
	a := &app.assets
	r := &a.renderer
	b := &app.watch.banner
	p := &b.prediction
	scale := app.scale
	h := line_height(r, .Bold, size) + 6 * scale
	top := y + CHAT_PADDING * scale / 8
	gap := BET_GAP * scale
	pen := x

	// Buttons from the left, each as wide as its label, or narrower to fit them
	// all on the line.
	Button :: struct {
		label:  string,
		fill:   Color,
		action: Bet_Action,
		value:  int,
	}
	buttons := make([dynamic]Button, context.temp_allocator)
	switch row {
	case .None:
		return
	case .Sending:
		on := p.outcomes[b.bet.choice - 1].title if b.bet.choice > 0 && b.bet.choice <= len(p.outcomes) else "it"
		draw_text_line(a, .Regular, size, pen, top + 3 * scale, fmt.tprintf("Betting on %s…", on), CHAT_SYSTEM_TEXT, w)
		return
	case .Mine:
		o := p.outcomes[p.mine_on]
		end, _ := draw_text_line(a, .Regular, size, pen, top + 3 * scale, fmt.tprintf("You: %s points on", format_viewers(p.mine)), CHAT_SYSTEM_TEXT, w)
		space := text_width(r, .Regular, size, " ")
		draw_text_line(a, .Bold, size, end + space, top + 3 * scale, o.title, PREDICTION_PINK if o.pink else PREDICTION_BLUE, x + w - end - space)
		return
	case .Outcomes:
		for o, i in p.outcomes {
			append(&buttons, Button{o.title, PREDICTION_PINK if o.pink else PREDICTION_BLUE, .Outcome, i})
		}
	case .Amounts:
		o := p.outcomes[b.bet.choice - 1]
		for amount in bet_amounts(app.watch.bonus.balance) {
			label := format_viewers(amount)
			if balance, known := app.watch.bonus.balance.?; known && amount == min(balance, PREDICTION_MAX_POINTS) {
				label = fmt.tprintf("All %s", label)
			}
			append(&buttons, Button{label, PREDICTION_PINK if o.pink else PREDICTION_BLUE, .Amount, amount})
		}
		append(&buttons, Button{"Cancel", BET_BUTTON, .Cancel, 0})
	}
	n := f32(len(buttons))
	most := (w - gap * (n - 1)) / n
	for button in buttons {
		// Cut short (its label too) when they don't all fit.
		bw := min(text_width(r, .Bold, size, button.label) + 16 * scale, most)
		rect := Rect{pen, top, bw, h}
		hovered := in_rect(rect, app.mouse.x, app.mouse.y)
		fill := button.fill
		if button.action == .Cancel {
			fill = BET_BUTTON_HOVER if hovered else BET_BUTTON
		} else if !hovered {
			fill.a = 190
		}
		draw_rect(r, rect, fill)
		label := fit_text(r, .Bold, size, button.label, bw - 8 * scale)
		draw_centered(r, .Bold, size, rect, label, CHAT_TEXT)
		append(&b.bet.hits, Bet_Hit{rect, button.action, button.value})
		pen += bw + gap
	}
	// Why the last try failed, after the outcomes to try again with.
	if b.bet.error != "" && row == .Outcomes && pen < x + w {
		text := fmt.tprintf("Couldn't bet: %s", bet_error_text(b.bet.error))
		draw_text_line(a, .Regular, size, pen, top + 3 * scale, text, CHAT_SYSTEM_TEXT, x + w - pen)
	}
}

// A click on a button under the prediction. Returns whether (x, y) was on one.
bet_click :: proc(app: ^App, x, y: f32) -> bool {
	bet := &app.watch.banner.bet
	for hit in bet.hits {
		if !in_rect(hit.rect, x, y) {
			continue
		}
		switch hit.action {
		case .Outcome:
			prediction_bet_reset(bet)
			bet.choice = hit.value + 1
		case .Amount:
			prediction_bet_start(app, bet.choice - 1, hit.value)
		case .Cancel:
			prediction_bet_reset(bet)
		case .Vote:
			poll_vote_start(app, hit.value)
		}
		return true
	}
	return false
}

Prediction_Bet_Job :: struct {
	client_id, token, login: string,
	event_id, outcome_id:    string,
	points, outcome:         int,
	session:                 int,
	// Why it didn't go through ("" if it did). Owned.
	error:                   string,
}

destroy_prediction_bet_job :: proc(p: ^Prediction_Bet_Job) {
	delete(p.client_id)
	delete(p.token)
	delete(p.login)
	delete(p.event_id)
	delete(p.outcome_id)
	delete(p.error)
}

// Bets `points` on outcome `outcome` (an index) of the prediction shown.
@(private = "file")
prediction_bet_start :: proc(app: ^App, outcome, points: int) {
	w := &app.watch
	b := &w.banner
	p := &b.prediction
	if b.bet.sending || !app.signed_in || p.locked || outcome < 0 || outcome >= len(p.outcomes) {
		return
	}
	delete(b.bet.error)
	b.bet.error = ""
	b.bet.sending = true
	jobs_add(
		&app.assets.jobs,
		run_prediction_bet_job,
		Prediction_Bet_Job {
			client_id = strings.clone(app.client_id),
			token = strings.clone(app.auth.access_token),
			login = strings.clone(w.channel),
			event_id = strings.clone(p.id),
			outcome_id = strings.clone(p.outcomes[outcome].id),
			points = points,
			outcome = outcome,
			session = app.session,
		},
	)
}

@(private = "file")
run_prediction_bet_job :: proc(job: ^Job) {
	p := &job.payload.(Prediction_Bet_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["event"] = p.event_id
	variables["outcome"] = p.outcome_id
	// New for each bet, so Twitch counts one sent twice once.
	variables["transaction"] = fmt.tprintf("%016x%016x", rand.uint64(), rand.uint64())
	code := make_prediction(p.client_id, p.token, make_prediction_query(p.points), variables)
	if code != "" {
		log.warnf("betting on a prediction failed: %s", code)
		p.error = strings.clone(code)
	}
}

// The points go in the query: variables are only strings here. Allocated with
// the temp allocator.
make_prediction_query :: proc(points: int) -> string {
	return fmt.tprintf(
		"mutation($event: ID!, $outcome: ID!, $transaction: ID!) {{ makePrediction(input: {{eventID: $event, outcomeID: $outcome, points: %d, transactionID: $transaction}}) {{ error {{ code }} }} }}",
		points,
	)
}

// Sends the bet; returns why it failed, or "" if it went through. Allocated with
// the temp allocator.
@(private = "file")
make_prediction :: proc(client_id, token, query: string, variables: map[string]string) -> string {
	body, err := gql_post(client_id, token, query, variables)
	if err != .None {
		return "REQUEST_FAILED"
	}
	return parse_make_prediction_response(body)
}

// Why Twitch refused the bet, or "" if it took it.
parse_make_prediction_response :: proc(body: []byte) -> string {
	r: struct {
		data:   struct {
			makePrediction: Maybe(struct {
				error: Maybe(struct {
					code: string,
				}),
			}),
		},
		errors: []struct {
			message: string,
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return "BAD_RESPONSE"
	}
	if len(r.errors) > 0 {
		graphql_error(r.errors[0].message)
		return "REQUEST_FAILED"
	}
	result, ok := r.data.makePrediction.?
	if !ok {
		return "BAD_RESPONSE"
	}
	if e, failed := result.error.?; failed {
		return e.code if e.code != "" else "REFUSED"
	}
	return ""
}

finish_prediction_bet_job :: proc(app: ^App, p: ^Prediction_Bet_Job) {
	w := &app.watch
	b := &w.banner
	if p.session != app.session || w.channel != p.login {
		return
	}
	b.bet.sending = false
	b.bet.choice = 0
	if p.error != "" {
		delete(b.bet.error)
		b.bet.error, p.error = p.error, ""
		return
	}
	// Shown as theirs straight away; asking again soon confirms it.
	if b.prediction.id == p.event_id {
		b.prediction.mine += p.points
		b.prediction.mine_on = p.outcome
	}
	if balance, known := w.bonus.balance.?; known {
		w.bonus.balance = max(0, balance - p.points)
	}
	b.next_at = 0
}
