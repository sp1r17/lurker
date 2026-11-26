package app

import "core:testing"

// The amounts offered are those the balance covers, then all of it, up to
// Twitch's limit for one person.
@(test)
bet_amounts_fit_the_balance :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, len(bet_amounts(nil)), len(BET_AMOUNTS))
	some := bet_amounts(2_500)
	testing.expect_value(t, len(some), 4)
	testing.expect_value(t, some[2], 1_000)
	testing.expect_value(t, some[3], 2_500)
	// Exactly an amount: no second button for all of it.
	testing.expect_value(t, len(bet_amounts(1_000)), 3)
	rich := bet_amounts(9_000_000)
	testing.expect_value(t, rich[len(rich) - 1], PREDICTION_MAX_POINTS)
	testing.expect_value(t, len(bet_amounts(0)), 0)
}

@(test)
bets_are_answered :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, parse_make_prediction_response(transmute([]byte)string(`{"data":{"makePrediction":{"error":null}}}`)), "")
	refused := parse_make_prediction_response(transmute([]byte)string(`{"data":{"makePrediction":{"error":{"code":"NOT_ENOUGH_POINTS"}}}}`))
	testing.expect_value(t, refused, "NOT_ENOUGH_POINTS")
	testing.expect_value(t, bet_error_text(refused), "not enough points")
	testing.expect_value(t, parse_make_prediction_response(transmute([]byte)string(`{"errors":[{"message":"unauthenticated"}],"data":{"makePrediction":null}}`)), "REQUEST_FAILED")
}

// Signed in, the prediction says what the user bet, and on which outcome.
@(test)
own_bet_is_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"data":{"channel":{"pinnedChatMessages":{"edges":[]},"activePredictionEvents":[{"id":"ev1","title":"Win?","status":"ACTIVE",` +
		`"self":{"prediction":{"points":500,"outcome":{"id":"o2"}}},` +
		`"outcomes":[{"id":"o1","title":"Yes","totalPoints":300,"color":"BLUE"},{"id":"o2","title":"No","totalPoints":100,"color":"PINK"}]}]}}}`
	pinned, prediction, _, ok := parse_chat_banner_response(transmute([]byte)body)
	defer destroy_chat_message(pinned)
	defer prediction_destroy(&prediction)
	testing.expect(t, ok)
	testing.expect_value(t, prediction.id, "ev1")
	testing.expect_value(t, prediction.outcomes[1].id, "o2")
	testing.expect_value(t, prediction.mine, 500)
	testing.expect_value(t, prediction.mine_on, 1)
}

@(test)
bet_query_is_made :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		make_prediction_query(10),
		"mutation($event: ID!, $outcome: ID!, $transaction: ID!) { makePrediction(input: {eventID: $event, outcomeID: $outcome, points: 10, transactionID: $transaction}) { error { code } } }",
	)
}

@(test)
votes_are_answered :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_vote_in_poll_response(transmute([]byte)string(`{"data":{"voteInPoll":{"error":null}}}`)), "")
	testing.expect_value(t, parse_vote_in_poll_response(transmute([]byte)string(`{"data":{"voteInPoll":{"error":{"code":"POLL_NOT_FOUND"}}}}`)), "POLL_NOT_FOUND")
	testing.expect_value(t, parse_vote_in_poll_response(transmute([]byte)string(`{"errors":[{"message":"Cannot query field \"x\""}]}`)), "REQUEST_FAILED")
	testing.expect_value(t, parse_vote_in_poll_response(transmute([]byte)string(`not json`)), "BAD_RESPONSE")
}

@(test)
own_vote_is_read :: proc(t: ^testing.T) {
	body := `{"data":{"user":{"viewablePoll":{"id":"p1","title":"Next game?","status":"ACTIVE","remainingDurationMilliseconds":30000,"settings":{"multichoice":{"isEnabled":true}},"choices":[{"id":"c1","title":"GTA","votes":{"total":3}},{"id":"c2","title":"Elden Ring","votes":{"total":5}}],"self":{"voter":{"choices":[{"pollChoice":{"id":"c2"}}]}}}}}}`
	poll, ok := parse_poll_response(transmute([]byte)string(body))
	defer poll_destroy(&poll)
	testing.expect(t, ok)
	testing.expect_value(t, poll.id, "p1")
	testing.expect(t, poll.multichoice)
	testing.expect_value(t, len(poll.choices), 2)
	testing.expect_value(t, poll.choices[0].id, "c1")
	testing.expect(t, !poll.choices[0].mine)
	testing.expect(t, poll.choices[1].mine)
}
