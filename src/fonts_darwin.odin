package app

import "core:os"

// Fonts that come with macOS, for characters Noto Sans lacks: symbols, then
// Chinese, Japanese and Korean. Apple Color Emoji has no outlines for
// stb_truetype to draw, so emoji come only from the emoji images.
@(private = "file")
FALLBACK_FONTS := [?]string {
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/Hiragino Sans GB.ttc",
	"/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
	"/System/Library/Fonts/AppleSDGothicNeo.ttc",
}

// The fallback fonts that are installed. Allocated with the temp allocator.
fallback_font_files :: proc() -> []Font_File {
	files := make([dynamic]Font_File, context.temp_allocator)
	for path in FALLBACK_FONTS {
		if os.exists(path) {
			append(&files, Font_File{path = path})
		}
	}
	return files[:]
}
