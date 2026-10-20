package app

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"
import "vendor:curl"

HTTP_TIMEOUT_SECONDS :: 20

Http_Response :: struct {
	status: int,
	// Allocated with the allocator passed to http_request.
	body:   []byte,
}

// A blocking request, for worker threads. A non-empty `post_body` makes it a POST.
// curl.global_init must have been called.
http_request :: proc(
	url: string,
	headers: []string = nil,
	post_body := "",
	allocator := context.allocator,
) -> (
	res: Http_Response,
	ok: bool,
) {
	h := curl.easy_init()
	if h == nil {
		return {}, false
	}
	defer curl.easy_cleanup(h)

	Sink :: struct {
		ctx:  runtime.Context,
		body: [dynamic]byte,
	}
	sink := Sink {
		ctx  = context,
		body = make([dynamic]byte, allocator),
	}
	write :: proc "c" (buffer: [^]byte, size, count: c.size_t, userdata: rawptr) -> c.size_t {
		sink := (^Sink)(userdata)
		context = sink.ctx
		append(&sink.body, ..buffer[:size * count])
		return size * count
	}

	curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.easy_setopt(h, .WRITEFUNCTION, write)
	curl.easy_setopt(h, .WRITEDATA, &sink)
	curl.easy_setopt(h, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(h, .TIMEOUT, c.long(HTTP_TIMEOUT_SECONDS))
	// Signals are process-wide; curl must not use them for timeouts on worker threads.
	curl.easy_setopt(h, .NOSIGNAL, c.long(1))
	curl.easy_setopt(h, .USERAGENT, cstring("twitch-app"))
	// Empty means every encoding curl supports (gzip, brotli...).
	curl.easy_setopt(h, .ACCEPT_ENCODING, cstring(""))

	list: ^curl.slist
	for header in headers {
		list = curl.slist_append(list, strings.clone_to_cstring(header, context.temp_allocator))
	}
	defer curl.slist_free_all(list)
	if list != nil {
		curl.easy_setopt(h, .HTTPHEADER, list)
	}
	if post_body != "" {
		curl.easy_setopt(h, .POSTFIELDS, strings.clone_to_cstring(post_body, context.temp_allocator))
	}

	if rc := curl.easy_perform(h); rc != .E_OK {
		log.warnf("%s %s failed: %s", "POST" if post_body != "" else "GET", url, curl.easy_strerror(rc))
		delete(sink.body)
		return {}, false
	}
	status: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &status)
	return {status = int(status), body = sink.body[:]}, true
}
