package app

import "core:testing"
import "core:time"
import "vendor:curl"

// Leaving a channel while its chat is still connecting must not wait for the
// 10-second connect timeout.
@(test)
chat_stops_while_connecting :: proc(t: ^testing.T) {
	curl.global_init(curl.GLOBAL_DEFAULT)
	defer curl.global_cleanup()
	chat: Chat
	// A reserved address nothing answers: connecting hangs until the timeout.
	chat.url = "wss://10.255.255.1:443"
	chat_start(&chat, "nobody", 0)
	time.sleep(300 * time.Millisecond)
	start := time.now()
	chat_stop(&chat)
	took := time.since(start)
	testing.expectf(t, took < 2 * time.Second, "stopping took %v", took)
}
