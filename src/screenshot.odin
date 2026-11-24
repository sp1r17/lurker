package app

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

// Screenshots of the video alone, at its own size (S): saved as PNG in a Lurker
// folder in the Pictures folder, named after the channel and the local time.

SCREENSHOT_NOTICE_MS :: 3000

// The folder screenshots go in, made if need be. Allocated with the temp
// allocator.
@(private = "file")
screenshot_dir :: proc() -> (dir: string, ok: bool) {
	pictures := pictures_dir()
	if pictures == "" {
		return "", false
	}
	joined, err := filepath.join({pictures, APP_NAME}, context.temp_allocator)
	if err != nil {
		return "", false
	}
	if mk := os.make_directory_all(joined); mk != nil && mk != .Exist {
		log.warnf("can't make %s: %v", joined, mk)
		return "", false
	}
	return joined, true
}

// The user's Pictures folder: on Linux the one named in user-dirs.dirs, as
// xdg-user-dir finds it; elsewhere, or without one, Pictures in the home folder.
// Allocated with the temp allocator.
pictures_dir :: proc() -> string {
	home := os.get_env("USERPROFILE" when ODIN_OS == .Windows else "HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	when ODIN_OS == .Linux {
		config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if config == "" {
			config = fmt.tprintf("%s/.config", home)
		}
		if data, err := os.read_entire_file(fmt.tprintf("%s/user-dirs.dirs", config), context.temp_allocator); err == nil {
			if dir := user_dirs_pictures(string(data), home); dir != "" {
				return dir
			}
		}
	}
	joined, _ := filepath.join({home, "Pictures"}, context.temp_allocator)
	return joined
}

// XDG_PICTURES_DIR from a user-dirs.dirs file (`XDG_PICTURES_DIR="$HOME/Pictures"`),
// with $HOME as `home`; "" if it has none, or only the home folder itself, which
// xdg-user-dir means as "not set". Allocated with the temp allocator.
user_dirs_pictures :: proc(text, home: string) -> string {
	for line in strings.split_lines(text, context.temp_allocator) {
		rest := strings.trim_space(line)
		if !strings.has_prefix(rest, "XDG_PICTURES_DIR=") {
			continue
		}
		value := strings.trim(rest[len("XDG_PICTURES_DIR="):], "\"")
		if strings.has_prefix(value, "$HOME") {
			value = fmt.tprintf("%s%s", home, value[len("$HOME"):])
		}
		value = strings.trim_right(value, "/")
		if value == "" || value == strings.trim_right(home, "/") || !strings.has_prefix(value, "/") {
			return ""
		}
		return value
	}
	return ""
}

// A screenshot's file name: the channel and the local time, without characters
// Windows doesn't allow. Allocated with the temp allocator.
screenshot_name :: proc(channel: string, dt: sdl.DateTime) -> string {
	who := channel if channel != "" else "lurker"
	return fmt.tprintf("%s %04d-%02d-%02d %02d.%02d.%02d.png", who, dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
}

// Saves the video's current picture, without Lurker's UI, at its own size; the
// PNG is written on a worker, and the notice says how it went.
watch_screenshot :: proc(app: ^App) {
	w := &app.watch
	if w.status != .Playing {
		return
	}
	dir, dir_ok := screenshot_dir()
	dt: sdl.DateTime
	now: sdl.Time
	if !dir_ok || !sdl.GetCurrentTime(&now) || !sdl.TimeToDateTime(now, &dt, true) {
		screenshot_done(app, false)
		return
	}
	path, err := filepath.join({dir, screenshot_name(w.channel, dt)}, context.temp_allocator)
	pixels, size, captured := player_capture(&app.player)
	if err != nil || !captured {
		delete(pixels)
		screenshot_done(app, false)
		return
	}
	jobs_add(&app.assets.jobs, run_screenshot_job, Screenshot_Job{pixels = pixels, size = size, path = strings.clone(path)})
}

Screenshot_Job :: struct {
	// RGBA rows, top first, and where the PNG goes. Owned.
	pixels: []u8,
	size:   [2]i32,
	path:   string,
	saved:  bool,
}

@(private = "file")
run_screenshot_job :: proc(job: ^Job) {
	j := &job.payload.(Screenshot_Job)
	surface := sdl.CreateSurfaceFrom(j.size.x, j.size.y, .RGBA32, raw_data(j.pixels), j.size.x * 4)
	if surface == nil {
		log.warnf("can't make the screenshot's image: %s", sdl.GetError())
		return
	}
	defer sdl.DestroySurface(surface)
	cpath := strings.clone_to_cstring(j.path, context.temp_allocator)
	j.saved = img.SavePNG(surface, cpath)
	if !j.saved {
		log.warnf("can't save %s: %s", j.path, sdl.GetError())
	}
}

finish_screenshot_job :: proc(app: ^App, j: ^Screenshot_Job) {
	screenshot_done(app, j.saved)
}

destroy_screenshot_job :: proc(j: ^Screenshot_Job) {
	delete(j.pixels)
	delete(j.path)
}

// Shows how saving the screenshot went.
screenshot_done :: proc(app: ^App, saved: bool) {
	app.watch.screenshot_until = app.assets.now_ms + SCREENSHOT_NOTICE_MS
	app.watch.screenshot_saved = saved
}

// The notice after S, centred near the top: where the screenshot went, or that
// it couldn't be saved.
draw_screenshot_notice :: proc(app: ^App) {
	w := &app.watch
	if app.assets.now_ms >= w.screenshot_until {
		return
	}
	if w.screenshot_saved {
		draw_notice(app, fmt.tprintf("Screenshot saved in %s", screenshot_folder_label()))
	} else {
		draw_notice(app, "Couldn't save the screenshot: the log says why")
	}
}

// Where screenshots go, as shown: ~ for the home folder. Allocated with the
// temp allocator.
@(private = "file")
screenshot_folder_label :: proc() -> string {
	dir, _ := filepath.join({pictures_dir(), APP_NAME}, context.temp_allocator)
	home := os.get_env("USERPROFILE" when ODIN_OS == .Windows else "HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(dir, home) {
		return fmt.tprintf("~%s", dir[len(home):])
	}
	return dir
}

// ms until the screenshot notice goes, for the main loop's wait; -1 if none.
screenshot_notice_wait :: proc(app: ^App) -> int {
	left := app.watch.screenshot_until - app.assets.now_ms
	return left if app.screen == .Watch && left > 0 else -1
}
