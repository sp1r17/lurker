package app

import "core:c"
import "core:log"
import "core:strings"
import "core:sync"
import "vendor:curl"

// Connects a WebSocket to `url`, checking `stop` every CHAT_STOP_CHECK_MS
// meanwhile: connecting can take until the timeout, and leaving a channel mustn't
// wait for it. (curl's progress callback, tried first, wasn't called while
// connecting everywhere.) The socket then goes to ws_send/ws_recv; ws_close
// releases it, whether it connected or not. `what` names it in the log.
ws_open :: proc(url: string, stop: ^bool, what: string) -> (h: ^curl.CURL, multi: ^curl.CURLM, ok: bool) {
	h = curl.easy_init()
	if h == nil {
		log.errorf("%s: curl init failed", what)
		return
	}
	curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	// 2 = connect, do the WebSocket upgrade, then hand the socket to ws_send/ws_recv.
	curl.easy_setopt(h, .CONNECT_ONLY, c.long(2))
	curl.easy_setopt(h, .CONNECTTIMEOUT, c.long(10))
	when ODIN_OS == .Windows {
		// Windows' certificate revocation check fails outright when it can't reach
		// the revocation servers (often under Wine); certificates are still checked.
		curl.easy_setopt(h, .SSL_OPTIONS, c.long(curl.SSLOPT_REVOKE_BEST_EFFORT))
	}
	// The WebSocket stays with the multi handle that connected it, until the end.
	multi = curl.multi_init()
	if multi == nil {
		return
	}
	curl.multi_add_handle(multi, h)
	for {
		running: c.int
		curl.multi_perform(multi, &running)
		if running == 0 {
			break
		}
		if sync.atomic_load(stop) {
			return
		}
		curl.multi_poll(multi, nil, 0, CHAT_STOP_CHECK_MS, nil)
	}
	queued: c.int
	msg := curl.multi_info_read(multi, &queued)
	if msg == nil || msg.msg != .DONE {
		return
	}
	if msg.data.result != .E_OK {
		log.warnf("%s: can't connect: %s", what, curl.easy_strerror(msg.data.result))
		return
	}
	return h, multi, true
}

ws_close :: proc(h: ^curl.CURL, multi: ^curl.CURLM) {
	if multi != nil {
		curl.multi_remove_handle(multi, h)
		curl.multi_cleanup(multi)
	}
	if h != nil {
		curl.easy_cleanup(h)
	}
}
