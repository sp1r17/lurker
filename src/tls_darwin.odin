package app

import "core:c"
import "vendor:curl"

// Lurker.app carries Homebrew's curl (macOS's own lacks WebSockets), whose OpenSSL
// would look for certificates in Homebrew's folders; this has it ask macOS's
// keychain instead.
curl_tls_options :: proc(h: ^curl.CURL) {
	curl.easy_setopt(h, .SSL_OPTIONS, c.long(curl.SSLOPT_NATIVE_CA))
}
