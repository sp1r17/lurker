package app

import "vendor:curl"

// curl's defaults find the system's certificates.
curl_tls_options :: proc(h: ^curl.CURL) {}
