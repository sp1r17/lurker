package app

import "core:testing"
import sdl "vendor:sdl3"

@(test)
user_dirs_pictures_reads_the_pictures_folder :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "# written by xdg-user-dirs-update\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_PICTURES_DIR=\"$HOME/Bilder\"\n"
	testing.expect_value(t, user_dirs_pictures(text, "/home/me"), "/home/me/Bilder")
	testing.expect_value(t, user_dirs_pictures(`XDG_PICTURES_DIR="/data/pics/"`, "/home/me"), "/data/pics")
	// The home folder itself means it isn't set, as does none.
	testing.expect_value(t, user_dirs_pictures(`XDG_PICTURES_DIR="$HOME/"`, "/home/me"), "")
	testing.expect_value(t, user_dirs_pictures(`XDG_MUSIC_DIR="$HOME/Music"`, "/home/me"), "")
}

@(test)
screenshot_name_has_the_channel_and_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dt := sdl.DateTime{year = 2026, month = 11, day = 3, hour = 9, minute = 5, second = 7}
	testing.expect_value(t, screenshot_name("lirik", dt), "lirik 2026-11-03 09.05.07.png")
	testing.expect_value(t, screenshot_name("", dt), "lurker 2026-11-03 09.05.07.png")
}
