package app

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"
import "core:sync"
import "vendor:curl"

HTTP_TIMEOUT_SECONDS :: 20

// Set when the app is quitting: requests in flight abort instead of making the
// quit wait for them.
@(private = "file")
requests_cancelled: bool

cancel_requests :: proc() {
	sync.atomic_store(&requests_cancelled, true)
}

// libcurl calls this often during a transfer, connecting included; non-zero aborts.
@(private = "file")
check_cancelled :: proc "c" (_: rawptr, _, _, _, _: curl.off_t) -> c.int {
	return 1 if sync.atomic_load(&requests_cancelled) else 0
}

// A job worker's handle, kept between its requests so they reuse its connections:
// a new TLS connection per emote makes a big emote set slow to show.
@(private = "file", thread_local)
kept_handle: ^curl.CURL

// Keeps connections open between this thread's requests, until http_keep_end.
// For long-lived threads only (the job workers).
http_keep_begin :: proc() {
	kept_handle = curl.easy_init()
}

http_keep_end :: proc() {
	if kept_handle != nil {
		curl.easy_cleanup(kept_handle)
		kept_handle = nil
	}
}

Http_Response :: struct {
	status: int,
	// Allocated with the allocator passed to http_request.
	body:   []byte,
}

// A blocking request, for worker threads. A non-empty `post_body` makes it a POST;
// `method` sets another ("DELETE"). curl.global_init must have been called.
http_request :: proc(
	url: string,
	headers: []string = nil,
	post_body := "",
	allocator := context.allocator,
	method := "",
) -> (
	res: Http_Response,
	ok: bool,
) {
	h := kept_handle
	if h != nil {
		// Back to the defaults, keeping its connections.
		curl.easy_reset(h)
	} else {
		h = curl.easy_init()
		if h == nil {
			return {}, false
		}
	}
	defer if h != kept_handle {
		curl.easy_cleanup(h)
	}

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
	curl.easy_setopt(h, .NOPROGRESS, c.long(0))
	curl.easy_setopt(h, .XFERINFOFUNCTION, check_cancelled)
	curl.easy_setopt(h, .USERAGENT, cstring(APP_ID))
	when ODIN_OS == .Windows {
		// Windows' certificate revocation check fails outright when it can't reach
		// the revocation servers (often under Wine); certificates are still checked.
		curl.easy_setopt(h, .SSL_OPTIONS, c.long(curl.SSLOPT_REVOKE_BEST_EFFORT))
	}
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
	if method != "" {
		curl.easy_setopt(h, .CUSTOMREQUEST, strings.clone_to_cstring(method, context.temp_allocator))
	}

	if rc := curl.easy_perform(h); rc != .E_OK {
		if rc == .E_ABORTED_BY_CALLBACK {
			delete(sink.body)
			return {}, false
		}
		log.warnf("%s %s failed: %s", method if method != "" else "POST" if post_body != "" else "GET", url, curl.easy_strerror(rc))
		delete(sink.body)
		return {}, false
	}
	status: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &status)
	return {status = int(status), body = sink.body[:]}, true
}
