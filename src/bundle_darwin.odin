package app

import "core:os"
import "core:path/filepath"

// The streamlink in Lurker.app (Contents/Resources/streamlink, with its own
// Python), when running from the app. Allocated with the temp allocator.
bundled_streamlink :: proc() -> (path: string, ok: bool) {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		return "", false
	}
	joined, join_err := filepath.join({dir, "..", "Resources", "streamlink", "streamlink"}, context.temp_allocator)
	if join_err != nil || !os.exists(joined) {
		return "", false
	}
	return joined, true
}
