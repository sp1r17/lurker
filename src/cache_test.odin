package app

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

@(test)
cache_prune_drops_oldest :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tmp, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil)
	base := fmt.tprintf("%s/lurker-cache-test-%d", tmp, time.now()._nsec)
	old_env, had_env := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator)
	os.set_env("XDG_CACHE_HOME", base)
	defer {
		if had_env {
			os.set_env("XDG_CACHE_HOME", old_env)
		} else {
			os.unset_env("XDG_CACHE_HOME")
		}
		os.remove_all(base)
	}

	dir, ok := cache_dir()
	testing.expect(t, ok)
	testing.expect(t, os.make_directory_all(dir) == nil)
	kilobyte := make([]byte, 1024, context.temp_allocator)
	for i in 0 ..< 5 {
		path, _ := filepath.join({dir, fmt.tprintf("file%d", i)}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, kilobyte) == nil)
		// Distinct modification times, oldest first.
		time.sleep(20 * time.Millisecond)
	}
	cache_prune(3 * 1024)

	files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	names := make(map[string]bool, allocator = context.temp_allocator)
	for f in files {
		names[f.name] = true
	}
	// Down to 80% of the limit: the two newest stay.
	testing.expect_value(t, len(files), 2)
	testing.expect(t, names["file3"] && names["file4"])
}
