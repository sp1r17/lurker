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

Resolve_Job :: struct {
	channel: string,
	// The watch session it's for; the caller drops the result if that's over.
	session: int,
	url:     string,
	err:     Stream_Error,
}

destroy_resolve_job :: proc(p: ^Resolve_Job) {
	delete(p.channel)
	delete(p.url)
}

request_stream_url :: proc(jobs: ^Jobs, channel: string, session: int) {
	jobs_add(jobs, run_resolve_job, Resolve_Job{channel = strings.clone(channel), session = session})
}

@(private = "file")
run_resolve_job :: proc(job: ^Job) {
	p := &job.payload.(Resolve_Job)
	p.url, p.err = resolve_stream_url(p.channel)
}
