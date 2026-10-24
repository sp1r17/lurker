package app

import "core:log"
import "core:os"
import "core:path/filepath"

// A windowed program has no console to log to, so on Windows the log also goes
// to %LOCALAPPDATA%\lurker\lurker.log, replaced on each run.
open_log_file :: proc() -> (logger: log.Logger, ok: bool) {
	dir := cache_dir() or_return
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		return {}, false
	}
	path, join_err := filepath.join({dir, "lurker.log"}, context.temp_allocator)
	if join_err != nil {
		return {}, false
	}
	file, err := os.create(path)
	if err != nil {
		return {}, false
	}
	return log.create_file_logger(file), true
}
