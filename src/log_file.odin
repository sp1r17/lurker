package app

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

// The log also goes to lurker.log in the cache folder (~/.cache/lurker,
// %LOCALAPPDATA%\lurker, ~/Library/Caches/lurker): a windowed program has no
// console to read it from. The previous run's is kept as lurker.old.log, so a
// crash's log is still there after starting Lurker again.
LOG_NAME :: "lurker.log"
OLD_LOG_NAME :: "lurker.old.log"
// How much of each log "Copy log" takes, from its end: together they fit in a
// GitHub issue (65536 characters).
COPIED_LOG_BYTES :: 28 * 1024

@(private = "file")
log_path :: proc(name: string) -> (path: string, ok: bool) {
	dir := cache_dir() or_return
	joined, err := filepath.join({dir, name}, context.temp_allocator)
	return joined, err == nil
}

open_log_file :: proc() -> (logger: log.Logger, ok: bool) {
	dir := cache_dir() or_return
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		return {}, false
	}
	path := log_path(LOG_NAME) or_return
	if old, has_old := log_path(OLD_LOG_NAME); has_old && os.exists(path) {
		_ = os.rename(path, old)
	}
	file, err := os.create(path)
	if err != nil {
		return {}, false
	}
	return log.create_file_logger(file), true
}

// The last `limit` bytes of `text`, from the start of a line.
log_tail :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	tail := text[len(text) - limit:]
	if nl := strings.index_byte(tail, '\n'); nl >= 0 {
		tail = tail[nl + 1:]
	}
	return tail
}

// Both logs' ends, for a bug report, with the version and platform first.
// Allocated with the temp allocator.
log_report :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Lurker %s on %v %v\n", APP_VERSION, ODIN_OS, ODIN_ARCH)
	for name, i in ([2]string{OLD_LOG_NAME, LOG_NAME}) {
		path, ok := log_path(name)
		if !ok {
			continue
		}
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			continue
		}
		fmt.sbprintf(&b, "\n--- %s ---\n", "previous run" if i == 0 else "this run")
		strings.write_string(&b, log_tail(string(data), COPIED_LOG_BYTES))
	}
	return strings.to_string(b)
}

// Copies the logs for a bug report. Returns whether it worked.
log_copy :: proc() -> bool {
	cstr := strings.clone_to_cstring(log_report(), context.temp_allocator)
	if !sdl.SetClipboardText(cstr) {
		log.warnf("can't copy the log: %s", sdl.GetError())
		return false
	}
	return true
}

// Opens the folder with the logs in the file manager.
log_open_folder :: proc() {
	if dir, ok := cache_dir(); ok {
		// C:\Users\... becomes file:///C:/Users/...
		slashed, _ := strings.replace_all(dir, "\\", "/", context.temp_allocator)
		open_url(fmt.tprintf("file://%s%s", "" if strings.has_prefix(slashed, "/") else "/", slashed))
	}
}
