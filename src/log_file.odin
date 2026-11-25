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

PRIVATE_OPEN :: "‹"
PRIVATE_CLOSE :: "›"

// Marks something in a log line that says who uses Lurker or what they watch (a
// channel, a drop, a link they opened). The log file keeps it, but "Copy log"
// puts a number in its place, since that copy goes into public bug reports.
// Allocated with the temp allocator.
log_private :: proc(value: string) -> string {
	return fmt.tprintf("%s%s%s", PRIVATE_OPEN, value, PRIVATE_CLOSE)
}

@(private = "file")
url_token_end :: proc(c: byte) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', '"', '\'', '<', '>', '(', ')', '[', ']', ',':
		return true
	}
	return false
}

@(private = "file")
name_byte :: proc(c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-', '.', 0x80 ..= 0xff:
		return true
	}
	return false
}

// `text` without what would tell strangers who sent it: each log_private value
// becomes ‹1›, ‹2›… (the same number for the same value, so a report can still
// tell one channel from two), those values in URLs too, the `home` folder
// becomes ~, and URLs lose their query (user IDs, logins, playback tokens).
// Allocated with the temp allocator.
log_scrub :: proc(text, home: string) -> string {
	numbers := make(map[string]int, context.temp_allocator)
	values := make([dynamic]string, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	rest := text
	for {
		open := strings.index(rest, PRIVATE_OPEN)
		if open < 0 {
			break
		}
		after := rest[open + len(PRIVATE_OPEN):]
		close := strings.index(after, PRIVATE_CLOSE)
		// Unmatched on its line: not one of ours, so it stays.
		if close < 0 || strings.index_byte(after[:close], '\n') >= 0 {
			strings.write_string(&b, rest[:open + len(PRIVATE_OPEN)])
			rest = after
			continue
		}
		value := after[:close]
		n, seen := numbers[value]
		if !seen {
			n = len(numbers) + 1
			numbers[value] = n
			append(&values, value)
		}
		fmt.sbprintf(&b, "%s%s%d%s", rest[:open], PRIVATE_OPEN, n, PRIVATE_CLOSE)
		rest = after[close + len(PRIVATE_CLOSE):]
	}
	strings.write_string(&b, rest)
	out := strings.to_string(b)

	if home != "" && home != "/" {
		hb := strings.builder_make(context.temp_allocator)
		rest = out
		for {
			at := strings.index(rest, home)
			if at < 0 {
				break
			}
			end := at + len(home)
			// /home/al isn't part of /home/alice.
			whole := end == len(rest) || !name_byte(rest[end])
			strings.write_string(&hb, rest[:at])
			strings.write_string(&hb, "~" if whole else home)
			rest = rest[end:]
		}
		strings.write_string(&hb, rest)
		out = strings.to_string(hb)
	}

	ub := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(out); {
		if url_token_end(out[i]) {
			strings.write_byte(&ub, out[i])
			i += 1
			continue
		}
		start := i
		for i < len(out) && !url_token_end(out[i]) {
			i += 1
		}
		token := out[start:i]
		if strings.contains(token, "://") || strings.has_prefix(token, "/") {
			if q := strings.index_byte(token, '?'); q >= 0 {
				token = fmt.tprintf("%s?…", token[:q])
			}
			for value in values {
				n := numbers[value]
				number := fmt.tprintf("%s%d%s", PRIVATE_OPEN, n, PRIVATE_CLOSE)
				// Logins are lowercase in URLs, display names may not be.
				for form in ([2]string{value, strings.to_lower(value, context.temp_allocator)}) {
					if len(form) >= 3 {
						token, _ = strings.replace_all(token, form, number, context.temp_allocator)
					}
				}
			}
		}
		strings.write_string(&ub, token)
	}
	return strings.to_string(ub)
}

// Both logs' ends, for a bug report, with the version and platform first, and
// scrubbed with log_scrub. Allocated with the temp allocator.
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
	home, _ := os.user_home_dir(context.temp_allocator)
	return log_scrub(strings.to_string(b), home)
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
