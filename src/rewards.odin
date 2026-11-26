package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// A message sent with a channel points reward carries only the reward's ID
// (custom-reward-id), so each chat looks up its channel's reward names when it
// joins, to label those messages with what was redeemed.

// Reward ID -> its title, for one channel. Owned.
Rewards :: struct {
	names:  map[string]string,
	loaded: bool,
}

rewards_destroy :: proc(r: ^Rewards) {
	for id, title in r.names {
		delete(id)
		delete(title)
	}
	delete(r.names)
	r^ = {}
}

// The label for a message sent with reward `id`: its name once known.
// Allocated with the default allocator.
reward_label :: proc(r: ^Rewards, id: string) -> string {
	if r != nil {
		if title, ok := r.names[id]; ok && title != "" {
			return fmt.aprintf("Redeemed %s", title)
		}
	}
	return strings.clone("Redeemed a reward")
}

// Labels `m` with its reward's name, if it was sent with one.
apply_reward_label :: proc(r: ^Rewards, m: ^Chat_Message) {
	if m.reward_id == "" || m.accent != .Reward {
		return
	}
	delete(m.label)
	m.label = reward_label(r, m.reward_id)
	// Laid out again with the new label.
	m.layout.height = 0
	m.card_layout.height = 0
}

rewards_request :: proc(app: ^App, p: ^Chat_Pane) {
	jobs_add(
		&app.assets.jobs,
		run_rewards_job,
		Rewards_Job{client_id = strings.clone(app.client_id), room_id = strings.clone(p.room_id), pane = p.id},
	)
}

Rewards_Job :: struct {
	client_id, room_id: string,
	pane:               int,
	// What was found. Owned.
	rewards:            Rewards,
}

destroy_rewards_job :: proc(p: ^Rewards_Job) {
	delete(p.client_id)
	delete(p.room_id)
	rewards_destroy(&p.rewards)
}

@(private = "file")
run_rewards_job :: proc(job: ^Job) {
	p := &job.payload.(Rewards_Job)
	variables := make(map[string]string, context.temp_allocator)
	variables["id"] = p.room_id
	body, err := gql_post(p.client_id, "", "query($id: ID!) { channel(id: $id) { communityPointsSettings { customRewards { id title } } } }", variables)
	if err != .None {
		return
	}
	p.rewards, _ = parse_rewards_response(body)
}

// The rewards in a channel(id) answer. Not ok if the answer isn't one.
parse_rewards_response :: proc(body: []byte) -> (rewards: Rewards, ok: bool) {
	r: struct {
		data: struct {
			channel: Maybe(struct {
				communityPointsSettings: Maybe(struct {
					customRewards: []struct {
						id, title: string,
					},
				}),
			}),
		},
	}
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return {}, false
	}
	channel := r.data.channel.? or_return
	rewards.loaded = true
	settings := channel.communityPointsSettings.? or_else {}
	for reward in settings.customRewards {
		if reward.id != "" && reward.id not_in rewards.names {
			rewards.names[strings.clone(reward.id)] = strings.clone(reward.title)
		}
	}
	return rewards, true
}

// The names arrived: kept with the pane, and its messages sent with a reward
// labelled with them.
finish_rewards_job :: proc(app: ^App, p: ^Rewards_Job) {
	pane := find_pane(app, p.pane)
	if pane == nil || !p.rewards.loaded || p.room_id != pane.room_id {
		return
	}
	rewards_destroy(&pane.rewards)
	pane.rewards, p.rewards = p.rewards, {}
	for &m in pane.view.messages {
		apply_reward_label(&pane.rewards, &m)
	}
	for &m in pane.delayed {
		apply_reward_label(&pane.rewards, &m)
	}
}
