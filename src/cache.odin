package app

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:time"

// Downloads that never change for a given URL (emote, badge and emoji images,
// avatars, the versioned emoji list: their URLs carry an ID or a version) are kept
// in ~/.cache/twitch-app, one file per URL named by its SHA-256, so later runs
// don't fetch them again.
CACHE_LIMIT_BYTES :: 300 * 1024 * 1024
// Pruning stops once the cache is down to this share of the limit, so it doesn't
// run again on the next start.
CACHE_PRUNE_TO :: 0.8
// Temporary files older than this are from a run that died mid-write.
CACHE_STALE_TEMP :: time.Minute

// ~/.cache/twitch-app, allocated with the temp allocator.
cache_dir :: proc() -> (dir: string, ok: bool) {
	base, err := os.user_cache_dir(context.temp_allocator)
	if err != nil {
		return "", false
	}
	joined, join_err := filepath.join({base, "twitch-app"}, context.temp_allocator)
	return joined, join_err == nil
}

@(private = "file")
cache_path :: proc(url: string) -> (path: string, ok: bool) {
	dir := cache_dir() or_return
	digest := hash.hash_string(.SHA256, url, context.temp_allocator)
	name := string(hex.encode(digest, context.temp_allocator))
	joined, err := filepath.join({dir, name}, context.temp_allocator)
	return joined, err == nil
}

// Like http_request, from the cache when it has the URL; a successful download is
// stored. The body is allocated with the temp allocator. Blocks: call from a
// worker thread.
cached_get :: proc(url: string) -> (res: Http_Response, from_cache: bool, ok: bool) {
	path, has_path := cache_path(url)
	if has_path {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			return {status = 200, body = data}, true, true
		}
	}
	res = http_request(url, allocator = context.temp_allocator) or_return
	if res.status == 200 && has_path {
		cache_store(path, res.body)
	}
	return res, false, true
}

// Writes to a temporary file, then renames it into place: a crash, or two workers
// fetching the same URL, never leaves a half-written file under the real name.
@(private = "file")
cache_store :: proc(path: string, data: []byte) {
	if err := os.make_directory_all(filepath.dir(path)); err != nil && err != .Exist {
		log.warnf("can't create the cache folder: %v", err)
		return
	}
	temp := fmt.tprintf("%s.%x.tmp", path, rand.uint64())
	if err := os.write_entire_file(temp, data); err != nil {
		return
	}
	if err := os.rename(temp, path); err != nil {
		_ = os.remove(temp)
	}
}

// Drops a cached file that turned out to be unusable.
cache_forget :: proc(url: string) {
	if path, ok := cache_path(url); ok {
		_ = os.remove(path)
	}
}

// Deletes the oldest files once the cache is over `limit` bytes, and temporary
// files left by a run that died mid-write.
cache_prune :: proc(limit: i64 = CACHE_LIMIT_BYTES) {
	dir, ok := cache_dir()
	if !ok {
		return
	}
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	now := time.now()
	kept := make([dynamic]os.File_Info, context.temp_allocator)
	total: i64
	for f in files {
		if f.type != .Regular {
			continue
		}
		if filepath.ext(f.name) == ".tmp" {
			if time.diff(f.modification_time, now) > CACHE_STALE_TEMP {
				_ = os.remove(f.fullpath)
			}
			continue
		}
		append(&kept, f)
		total += f.size
	}
	if total <= limit {
		return
	}
	slice.sort_by(kept[:], proc(a, b: os.File_Info) -> bool {
		return time.diff(a.modification_time, b.modification_time) > 0
	})
	removed := 0
	for f in kept {
		if total <= i64(f64(limit) * CACHE_PRUNE_TO) {
			break
		}
		if os.remove(f.fullpath) == nil {
			total -= f.size
			removed += 1
		}
	}
	log.infof("cache: removed %d old files", removed)
}

Cache_Prune_Job :: struct {}

cache_request_prune :: proc(jobs: ^Jobs) {
	jobs_add(jobs, proc(_: ^Job) {cache_prune()}, Cache_Prune_Job{})
}
