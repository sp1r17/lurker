package app

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "vendor:curl"

HTTP_TIMEOUT_SECONDS :: 20

// The most a response can hold, decompressed, unless a request allows more: the
// largest Lurker expects (emote sets, Twitch's pages and scripts) are a few MB.
// A server sending more, or a small compressed response that unpacks to
// gigabytes, has the request fail instead of using up memory.
HTTP_MAX_BYTES :: 32 * 1024 * 1024

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
// `method` sets another ("DELETE"). A response over `max_bytes` fails it.
// curl.global_init must have been called.
http_request :: proc(
	url: string,
	headers: []string = nil,
	post_body := "",
	allocator := context.allocator,
	method := "",
	max_bytes := HTTP_MAX_BYTES,
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
		ctx:       runtime.Context,
		body:      [dynamic]byte,
		max_bytes: int,
		too_big:   bool,
	}
	sink := Sink {
		ctx       = context,
		body      = make([dynamic]byte, allocator),
		max_bytes = max_bytes,
	}
	write :: proc "c" (buffer: [^]byte, size, count: c.size_t, userdata: rawptr) -> c.size_t {
		sink := (^Sink)(userdata)
		context = sink.ctx
		n := int(size * count)
		// Counted after decompression. Taking less than it was given stops curl.
		if len(sink.body) + n > sink.max_bytes {
			sink.too_big = true
			return 0
		}
		append(&sink.body, ..buffer[:n])
		return c.size_t(n)
	}

	curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.easy_setopt(h, .WRITEFUNCTION, write)
	curl.easy_setopt(h, .WRITEDATA, &sink)
	// Refused at once when the response says it's bigger; the write callback
	// catches one that doesn't say, or says less.
	curl.easy_setopt(h, .MAXFILESIZE_LARGE, curl.off_t(max_bytes))
	curl.easy_setopt(h, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(h, .TIMEOUT, c.long(HTTP_TIMEOUT_SECONDS))
	// Signals are process-wide; curl must not use them for timeouts on worker threads.
	curl.easy_setopt(h, .NOSIGNAL, c.long(1))
	curl.easy_setopt(h, .NOPROGRESS, c.long(0))
	curl.easy_setopt(h, .XFERINFOFUNCTION, check_cancelled)
	curl.easy_setopt(h, .USERAGENT, cstring(APP_ID))
	curl_tls_options(h)
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
		if sink.too_big || rc == .E_FILESIZE_EXCEEDED {
			limit := fmt.tprintf("%d MB", max_bytes >> 20) if max_bytes >= 1 << 20 else fmt.tprintf("%d KB", max_bytes >> 10)
			log.warnf("%s is bigger than the %s allowed; not downloading it", url, limit)
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

// One round trip to `host` over the network, in ms: how long a TCP connection
// to it (port 443) takes to open, less the name lookup. A fresh connection each
// time, so it's measured rather than reused. Blocking: for a job.
http_ping :: proc(host: string) -> (ms: f64, ok: bool) {
	h := curl.easy_init()
	if h == nil {
		return 0, false
	}
	defer curl.easy_cleanup(h)
	curl.easy_setopt(h, .URL, strings.clone_to_cstring(strings.concatenate({"https://", host, "/"}, context.temp_allocator), context.temp_allocator))
	curl.easy_setopt(h, .CONNECT_ONLY, c.long(1))
	curl.easy_setopt(h, .TIMEOUT, c.long(5))
	curl.easy_setopt(h, .NOSIGNAL, c.long(1))
	curl.easy_setopt(h, .NOPROGRESS, c.long(0))
	curl.easy_setopt(h, .XFERINFOFUNCTION, check_cancelled)
	curl_tls_options(h)
	if curl.easy_perform(h) != .E_OK {
		return 0, false
	}
	lookup, connect: curl.off_t
	curl.easy_getinfo(h, .NAMELOOKUP_TIME_T, &lookup)
	curl.easy_getinfo(h, .CONNECT_TIME_T, &connect)
	// In microseconds.
	return f64(connect - lookup) / 1000, connect > 0
}
