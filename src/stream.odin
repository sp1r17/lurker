package app

import "core:log"
import "core:os"
import "core:strings"

Stream_Error :: enum {
	None,
	Streamlink_Failed,
	Offline,
}

// Asks streamlink for the HLS URL of a channel's best quality. The URL is allocated
// with the context allocator.
resolve_stream_url :: proc(channel: string) -> (url: string, err: Stream_Error) {
	page := strings.concatenate({"https://twitch.tv/", channel}, context.temp_allocator)
	state, stdout, stderr, exec_err := os.process_exec(
		{command = {"streamlink", "--stream-url", page, "best"}},
		context.temp_allocator,
	)
	if exec_err != nil {
		log.errorf("can't run streamlink: %v", exec_err)
		return "", .Streamlink_Failed
	}
	out := strings.trim_space(string(stdout))
	if !state.success {
		// streamlink reports errors on stdout when --stream-url is given.
		if strings.contains(out, "No playable streams") {
			return "", .Offline
		}
		log.errorf("streamlink failed: %s %s", out, strings.trim_space(string(stderr)))
		return "", .Streamlink_Failed
	}
	return strings.clone(out), .None
}
