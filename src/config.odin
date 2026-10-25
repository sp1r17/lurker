package app

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The app's name in its folders (~/.config/lurker, ~/.cache/lurker), app ID and
// window title.
APP_ID :: "lurker"
APP_NAME :: "Lurker"
// This release's version: bumped with the release entry in the metainfo (a test
// checks they match).
APP_VERSION :: "0.4.0"

// The client ID SmartTwitchTV signs in with (it belongs to Twitch's Android TV app),
// so signing in needs no app registered on dev.twitch.tv. Twitch could restrict it
// at any time; client_id in config.json or TWITCH_CLIENT_ID replaces it.
DEFAULT_CLIENT_ID :: "ue6666qo983tsx6so1t0vnawi233wa"

Config :: struct {
	// The client ID for signing in and for Twitch's API.
	client_id: string,
}

// config.json in the working directory, for running from the source tree, or
// else ~/.config/lurker/config.json (beside auth.json), for an installed
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
}
