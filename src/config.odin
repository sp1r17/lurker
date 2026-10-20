package app

import "core:encoding/json"
import "core:os"
import "core:strings"

CONFIG_PATH :: "config.json"

Config :: struct {
	channels:     []string,
	poll_seconds: int,
}

// Twitch app credentials come from the environment, so they never land in the config
// or in git.
Credentials :: struct {
	client_id:     string,
	client_secret: string,
}

Config_Error :: enum {
	None,
	Read_Failed,
	Bad_Json,
	No_Channels,
	Bad_Channel,
}

load_config :: proc(path: string) -> (c: Config, err: Config_Error) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, .Read_Failed
	}
	defer delete(data)
	return parse_config(data)
}

parse_config :: proc(data: []byte) -> (c: Config, err: Config_Error) {
	if json.unmarshal(data, &c) != nil {
		destroy_config(c)
		return {}, .Bad_Json
	}
	if len(c.channels) == 0 {
		destroy_config(c)
		return {}, .No_Channels
	}
	// Logins go straight into the request URL, so anything but Twitch's login
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
	for channel in c.channels {
		delete(channel)
	}
	delete(c.channels)
}

load_credentials :: proc() -> (creds: Credentials, ok: bool) {
	creds.client_id = os.get_env("TWITCH_CLIENT_ID", context.allocator)
	creds.client_secret = os.get_env("TWITCH_CLIENT_SECRET", context.allocator)
	if creds.client_id == "" || creds.client_secret == "" {
		destroy_credentials(creds)
		return {}, false
	}
	return creds, true
}

destroy_credentials :: proc(creds: Credentials) {
	delete(creds.client_id)
	delete(creds.client_secret)
}
