package app

import "core:log"

// The log goes to the terminal only: run from one, or see the journal.
open_log_file :: proc() -> (logger: log.Logger, ok: bool) {
	return {}, false
}
