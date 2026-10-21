package app

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The client ID SmartTwitchTV signs in with (it belongs to Twitch's Android TV app),
// so signing in needs no app registered on dev.twitch.tv. Twitch could restrict it
// at any time; client_id in config.json or TWITCH_CLIENT_ID replaces it.
DEFAULT_CLIENT_ID :: "ue6666qo983tsx6so1t0vnawi233wa"

Config :: struct {
	// The client ID for signing in and for Twitch's API.
	client_id:    string,
	channels:     []string,
	poll_seconds: int,
}

// config.json in the working directory, for running from the source tree, or
// else ~/.config/twitch-app/config.json (beside auth.json), for an installed
// copy. Allocated with the temp allocator.
config_path :: proc() -> string {
	if os.exists("config.json") {
		return "config.json"
	}
	auth, ok := auth_path()
	if !ok {
		return "config.json"
	}
	joined, err := filepath.join({filepath.dir(auth), "config.json"}, context.temp_allocator)
	return joined if err == nil else "config.json"
}

Config_Error :: enum {
	None,
	Read_Failed,
	Bad_Json,
	Bad_Channel,
}

// A missing config file means the defaults.
load_config :: proc(path: string) -> (c: Config, err: Config_Error) {
	if !os.exists(path) {
		c, err = parse_config(transmute([]byte)string("{}"))
	} else {
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			return {}, .Read_Failed
		}
		defer delete(data)
		c, err = parse_config(data)
	}
	if err == .None {
		if id := os.get_env("TWITCH_CLIENT_ID", context.allocator); id != "" {
			delete(c.client_id)
			c.client_id = id
		} else {
			delete(id)
		}
		if c.client_id == "" {
			c.client_id = strings.clone(DEFAULT_CLIENT_ID)
		}
	}
	return
}

parse_config :: proc(data: []byte) -> (c: Config, err: Config_Error) {
	if json.unmarshal(data, &c) != nil {
		destroy_config(c)
		return {}, .Bad_Json
	}
	// Logins go straight into request URLs, so anything but Twitch's login
	// characters is rejected. Twitch matches logins in lowercase.
	for &channel in c.channels {
		if !valid_login(channel) {
			destroy_config(c)
			return {}, .Bad_Channel
		}
		lower := strings.to_lower(channel)
		delete(channel)
		channel = lower
	}
	if c.poll_seconds <= 0 {
		c.poll_seconds = 60
	}
	return c, .None
}

valid_login :: proc(login: string) -> bool {
	if len(login) == 0 || len(login) > 25 {
		return false
	}
	for c in transmute([]byte)login {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		case:
			return false
		}
	}
	return true
}

destroy_config :: proc(c: Config) {
	delete(c.client_id)
	for channel in c.channels {
		delete(channel)
	}
	delete(c.channels)
}
