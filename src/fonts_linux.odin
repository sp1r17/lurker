package app

import "core:c"
import "core:strings"

// What to ask fontconfig for, in order, for characters Noto Sans lacks: within a
// group the first font that's installed is used. stb_truetype can't read colour
// emoji or variable fonts (Fedora's default NotoSansCJK-VF.ttc), so these are
// monochrome and static.
@(private = "file")
FALLBACK_QUERIES := [?][]cstring {
	{"Noto Emoji"},
	{"Noto Sans Symbols 2"},
	// CJK: Noto Sans CJK covers all of it; the others most of Chinese and Japanese.
	{"Noto Sans CJK JP", "Source Han Sans", "WenQuanYi Micro Hei", "Droid Sans Fallback", ":lang=ja"},
	// Korean, if the font above lacks it.
	{":lang=ko"},
}

// The system fonts to fall back on, from fontconfig, which also finds the host's
// fonts inside a Flatpak. Allocated with the temp allocator.
fallback_font_files :: proc() -> []Font_File {
	files := make([dynamic]Font_File, context.temp_allocator)
	if FcInit() == 0 {
		return nil
	}
	for group in FALLBACK_QUERIES {
		for query in group {
			if file, found := find_font(query); found {
				if !has_font_file(files[:], file) {
					append(&files, file)
				}
				break
			}
		}
	}
	return files[:]
}

// One face of a collection is enough: the others share its characters.
@(private = "file")
has_font_file :: proc(files: []Font_File, file: Font_File) -> bool {
	for f in files {
		if f.path == file.path {
			return true
		}
	}
	return false
}

// fontconfig's weight for regular text.
@(private = "file")
FC_WEIGHT_REGULAR :: 80

// The static font matching `query` (fontconfig's pattern syntax) closest to a
// regular weight.
@(private = "file")
find_font :: proc(query: cstring) -> (file: Font_File, found: bool) {
	pattern := FcNameParse(query)
	if pattern == nil {
		return
	}
	defer FcPatternDestroy(pattern)
	objects := FcObjectSetCreate()
	defer FcObjectSetDestroy(objects)
	FcObjectSetAdd(objects, "file")
	FcObjectSetAdd(objects, "index")
	FcObjectSetAdd(objects, "variable")
	FcObjectSetAdd(objects, "weight")
	set := FcFontList(nil, pattern, objects)
	if set == nil {
		return
	}
	defer FcFontSetDestroy(set)
	best_distance := max(int)
	for i in 0 ..< int(set.nfont) {
		font := set.fonts[i]
		path: cstring
		index: c.int
		variable: c.int
		weight := c.int(FC_WEIGHT_REGULAR)
		if FcPatternGetString(font, "file", 0, &path) != .Match {
			continue
		}
		FcPatternGetInteger(font, "index", 0, &index)
		FcPatternGetBool(font, "variable", 0, &variable)
		FcPatternGetInteger(font, "weight", 0, &weight)
		// A variable font, or one of its named instances (index above 0xFFFF).
		if variable != 0 || index > 0xFFFF || strings.contains(string(path), "-VF") {
			continue
		}
		if distance := abs(int(weight) - FC_WEIGHT_REGULAR); distance < best_distance {
			best_distance = distance
			file = {strings.clone(string(path), context.temp_allocator), int(index)}
			found = true
		}
	}
	return
}

@(private = "file")
Fc_Result :: enum c.int {
	Match,
	No_Match,
	Type_Mismatch,
	No_Id,
	Out_Of_Memory,
}

@(private = "file")
Fc_Font_Set :: struct {
	nfont: c.int,
	sfont: c.int,
	fonts: [^]rawptr,
}

foreign import fontconfig "system:fontconfig"

@(default_calling_convention = "c", private = "file")
foreign fontconfig {
	FcInit :: proc() -> c.int ---
	FcNameParse :: proc(name: cstring) -> rawptr ---
	FcPatternDestroy :: proc(p: rawptr) ---
	FcObjectSetCreate :: proc() -> rawptr ---
	FcObjectSetAdd :: proc(os: rawptr, object: cstring) -> c.int ---
	FcObjectSetDestroy :: proc(os: rawptr) ---
	FcFontList :: proc(config: rawptr, p: rawptr, os: rawptr) -> ^Fc_Font_Set ---
	FcFontSetDestroy :: proc(s: ^Fc_Font_Set) ---
	FcPatternGetString :: proc(p: rawptr, object: cstring, n: c.int, s: ^cstring) -> Fc_Result ---
	FcPatternGetInteger :: proc(p: rawptr, object: cstring, n: c.int, i: ^c.int) -> Fc_Result ---
	FcPatternGetBool :: proc(p: rawptr, object: cstring, n: c.int, b: ^c.int) -> Fc_Result ---
}
