package app

import "core:os"
import "core:path/filepath"

// Fonts that come with Windows 10 and 11, for characters Noto Sans lacks: emoji
// and symbols, then Chinese, Japanese and Korean. Segoe UI Emoji's colour layers
// are ignored (stb_truetype can't draw them), leaving its outlines.
@(private = "file")
FALLBACK_FONTS := [?]string{"seguiemj.ttf", "seguisym.ttf", "msyh.ttc", "YuGothR.ttc", "malgun.ttf"}

// The fallback fonts installed in %WINDIR%\Fonts. Allocated with the temp allocator.
fallback_font_files :: proc() -> []Font_File {
	windir := os.get_env("WINDIR", context.temp_allocator)
	if windir == "" {
		windir = `C:\Windows`
	}
	files := make([dynamic]Font_File, context.temp_allocator)
	for name in FALLBACK_FONTS {
		path, err := filepath.join({windir, "Fonts", name}, context.temp_allocator)
		if err == nil && os.exists(path) {
			append(&files, Font_File{path = path})
		}
	}
	return files[:]
}
