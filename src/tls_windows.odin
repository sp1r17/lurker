package app

import "core:c"
import "vendor:curl"

// Windows' certificate revocation check fails outright when it can't reach the
// revocation servers (often under Wine); certificates are still checked.
curl_tls_options :: proc(h: ^curl.CURL) {
	curl.easy_setopt(h, .SSL_OPTIONS, c.long(curl.SSLOPT_REVOKE_BEST_EFFORT))
}
