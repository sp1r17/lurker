package app

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:path/filepath"

// Each file Lurker saves state in (layout.json, blocked.json, watched.json and
// auth.json) records the version of its format, so a later Lurker can tell an
// old file from a current one and upgrade it instead of misreading it or starting
// over. A file from before versions counts as version 0.

// Where saved state goes instead of beside auth.json, for tests (set per thread,
// as tests run in parallel). auth.json stays where it is.
@(thread_local)
state_dir_override: string

// The folder layout.json and the other saved state go in.
state_dir :: proc() -> (dir: string, ok: bool) {
	if state_dir_override != "" {
		return state_dir_override, true
	}
	auth := auth_path() or_return
	return filepath.dir(auth), true
}

// `name` in the saved state's folder. Allocated with the temp allocator.
state_path :: proc(name: string) -> (path: string, ok: bool) {
	dir := state_dir() or_return
	joined, err := filepath.join({dir, name}, context.temp_allocator)
	return joined, err == nil
}

Saved_Read :: enum {
	Missing,
	Read,
	// Not a JSON object: a copy is kept beside it before it's saved over.
	Unreadable,
}

// Reads the saved file at `path`, and the version of its format (0 for a file
// from before versions). A file from a newer Lurker than this has a copy kept
// beside it, since saving here would drop what this version doesn't know. `data`
// is allocated with the temp allocator.
saved_read :: proc(path: string, current_version: int) -> (data: []byte, version: int, result: Saved_Read) {
	read, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, 0, .Missing
	}
	found, ok := saved_version(read)
	if !ok {
		saved_unreadable(path)
		return nil, 0, .Unreadable
	}
	if found > current_version {
		kept := fmt.tprintf("%s.v%d", path, found)
		log.warnf("%s is from a newer Lurker (format %d); keeping a copy as %s", filepath.base(path), found, filepath.base(kept))
		if copy_err := os.copy_file(kept, path); copy_err != nil {
			log.warnf("can't copy %s: %v", path, copy_err)
		}
	}
	return read, found, .Read
}

// Keeps a copy of a saved file that can't be read, as `<name>.unreadable`,
// before it's saved over.
saved_unreadable :: proc(path: string) {
	kept := fmt.tprintf("%s.unreadable", path)
	log.warnf("%s is unreadable; keeping a copy as %s", filepath.base(path), filepath.base(kept))
	if err := os.copy_file(kept, path); err != nil {
		log.warnf("can't copy %s: %v", path, err)
	}
}

// The "version" in a saved file's JSON object, or 0 if it has none. False if it
// isn't a JSON object at all.
saved_version :: proc(data: []byte) -> (version: int, ok: bool) {
	value, err := json.parse(data, allocator = context.temp_allocator)
	if err != nil {
		return 0, false
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return 0, false
	}
	#partial switch v in obj["version"] {
	case json.Integer:
		return int(v), true
	case json.Float:
		return int(v), true
	}
	return 0, true
}

// Writes `data` to a temporary file beside `path`, then renames it into place,
// so a crash mid-save never leaves a half-written file. `private` files can only
// be read by the user.
save_file :: proc(path: string, data: []byte, private := false) -> bool {
	if err := os.make_directory_all(filepath.dir(path), {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		log.warnf("can't create %s: %v", filepath.dir(path), err)
		return false
	}
	temp := fmt.tprintf("%s.%x.tmp", path, rand.uint64())
	perm := os.Permissions{.Read_User, .Write_User} if private else os.Permissions_Read_All + {.Write_User}
	if err := os.write_entire_file(temp, data, perm); err != nil {
		log.warnf("can't save %s: %v", path, err)
		_ = os.remove(temp)
		return false
	}
	if err := os.rename(temp, path); err != nil {
		log.warnf("can't save %s: %v", path, err)
		_ = os.remove(temp)
		return false
	}
	return true
}
