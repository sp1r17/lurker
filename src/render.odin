package app

import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import fs "vendor:fontstash"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

FONT_REGULAR_DATA :: #load("../assets/fonts/noto_sans/NotoSans-Regular.ttf")
FONT_BOLD_DATA :: #load("../assets/fonts/noto_sans/NotoSans-Bold.ttf")
FONT_ATLAS_SIZE :: 1024

// A font file, and which face in it (a .ttc holds several).
Font_File :: struct {
	path:  string,
	index: int,
}

Font :: enum {
	Regular,
	Bold,
}

Rect :: struct {
	x, y, w, h: f32,
}

// Batched 2D drawing in window pixels, origin top left. Rectangles and text share
// fontstash's atlas (its corner texels are white), so they draw in one batch; an
// image switches the texture and flushes the batch.
Renderer :: struct {
	program:      u32,
	vao, vbo:     u32,
	u_screen:     i32,
	u_mode:       i32,
	vertices:     [dynamic]Vertex,
	mode:         Draw_Mode,
	texture:      u32,
	screen:       [2]f32,
	fonts:        fs.FontContext,
	font_ids:     [Font]int,
	font_texture: u32,
	// The atlas size the texture was made for; fontstash doubles the atlas when full.
	font_texture_size: [2]int,
	// Every text size is multiplied by this: the user's text size (Ctrl+= and Ctrl+-).
	text_scale:   f32,
}

Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: Color,
}

Draw_Mode :: enum i32 {
	// Alpha from the texture's red channel: the font atlas.
	Alpha_Texture = 0,
	// Plain RGBA texture.
	Rgba_Texture  = 1,
}

@(private = "file")
VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
uniform vec2 u_screen;
out vec2 v_uv;
out vec4 v_color;
void main() {
	gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
	v_uv = a_uv;
	v_color = a_color;
}
`

@(private = "file")
FRAGMENT_SHADER :: `#version 330 core
in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_texture;
uniform int u_mode;
out vec4 o_color;
void main() {
	vec4 t = texture(u_texture, v_uv);
	// stb_truetype's unhinted coverage, blended as is, draws light text on the
	// dark UI thin: raising it fills in the strokes' soft edges.
	float coverage = pow(t.r, 0.75);
	o_color = u_mode == 0 ? vec4(v_color.rgb, v_color.a * coverage) : t * v_color;
}
`

renderer_init :: proc(r: ^Renderer) -> bool {
	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		log.error("can't compile the UI shaders")
		return false
	}
	r.program = program
	r.text_scale = 1
	r.u_screen = gl.GetUniformLocation(program, "u_screen")
	r.u_mode = gl.GetUniformLocation(program, "u_mode")

	gl.GenVertexArrays(1, &r.vao)
	gl.GenBuffers(1, &r.vbo)
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, size_of(Vertex), offset_of(Vertex, color))

	fs.Init(&r.fonts, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, .TOPLEFT)
	r.font_ids[.Regular] = fs.AddFontMem(&r.fonts, "regular", FONT_REGULAR_DATA, false)
	r.font_ids[.Bold] = fs.AddFontMem(&r.fonts, "bold", FONT_BOLD_DATA, false)
	// For what Noto Sans lacks: emoji, symbols, CJK. Each platform picks its own
	// (fonts_linux.odin).
	for file in fallback_font_files() {
		add_fallback_font(r, file)
	}
	fs.SetAlignVertical(&r.fonts, .TOP)
	gl.GenTextures(1, &r.font_texture)
	upload_font_atlas(r)
	return true
}

@(private = "file")
add_fallback_font :: proc(r: ^Renderer, file: Font_File) {
	data, err := os.read_entire_file(file.path, context.allocator)
	if err != nil {
		return
	}
	// fontstash doesn't check that a font loads, and using one that didn't crashes.
	info: stbtt.fontinfo
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), i32(file.index))
	if offset < 0 || !stbtt.InitFont(&info, raw_data(data), offset) {
		log.warnf("can't use fallback font %s", file.path)
		delete(data)
		return
	}
	log.infof("fallback font: %s", file.path)
	id := fs.AddFontMem(&r.fonts, file.path, data, true, file.index)
	for base in r.font_ids {
		fs.AddFallbackFont(&r.fonts, base, id)
	}
}

renderer_destroy :: proc(r: ^Renderer) {
	fs.Destroy(&r.fonts)
	gl.DeleteTextures(1, &r.font_texture)
	gl.DeleteBuffers(1, &r.vbo)
	gl.DeleteVertexArrays(1, &r.vao)
	gl.DeleteProgram(r.program)
	delete(r.vertices)
}

@(private = "file")
upload_font_atlas :: proc(r: ^Renderer) {
	gl.BindTexture(gl.TEXTURE_2D, r.font_texture)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.R8,
		i32(r.fonts.width),
		i32(r.fonts.height),
		0,
		gl.RED,
		gl.UNSIGNED_BYTE,
		raw_data(r.fonts.textureData),
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	r.font_texture_size = {r.fonts.width, r.fonts.height}
}

// Starts a frame drawing into the default framebuffer of the given size.
renderer_begin :: proc(r: ^Renderer, width, height: i32) {
	r.screen = {f32(width), f32(height)}
	gl.Viewport(0, 0, width, height)
	// mpv's rendering leaves its own framebuffer and state bound.
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	r.mode = .Alpha_Texture
	r.texture = r.font_texture
}

// Draws what's batched. Returns false if the font atlas grew during the frame:
// text drawn before that has stale texture coordinates, so draw the frame again.
renderer_end :: proc(r: ^Renderer) -> (frame_ok: bool) {
	flush(r)
	if r.font_texture_size != {r.fonts.width, r.fonts.height} {
		upload_font_atlas(r)
		return false
	}
	return true
}

@(private = "file")
flush :: proc(r: ^Renderer) {
	if len(r.vertices) == 0 {
		return
	}
	// Glyphs rasterized this frame are in the atlas but not yet in the texture.
	if r.texture == r.font_texture && r.font_texture_size == {r.fonts.width, r.fonts.height} {
		dirty: [4]f32
		if fs.ValidateTexture(&r.fonts, &dirty) {
			upload_font_atlas(r)
		}
	}
	gl.UseProgram(r.program)
	gl.Uniform2f(r.u_screen, r.screen.x, r.screen.y)
	gl.Uniform1i(r.u_mode, i32(r.mode))
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, r.texture)
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(r.vertices) * size_of(Vertex), raw_data(r.vertices), gl.STREAM_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(r.vertices)))
	clear(&r.vertices)
}

@(private = "file")
use :: proc(r: ^Renderer, mode: Draw_Mode, texture: u32) {
	if r.mode != mode || r.texture != texture {
		flush(r)
		r.mode = mode
		r.texture = texture
	}
}

@(private = "file")
push_quad :: proc(r: ^Renderer, x0, y0, x1, y1, u0, v0, u1, v1: f32, color: Color) {
	append(
		&r.vertices,
		Vertex{{x0, y0}, {u0, v0}, color},
		Vertex{{x1, y0}, {u1, v0}, color},
		Vertex{{x1, y1}, {u1, v1}, color},
		Vertex{{x0, y0}, {u0, v0}, color},
		Vertex{{x1, y1}, {u1, v1}, color},
		Vertex{{x0, y1}, {u0, v1}, color},
	)
}

// Limits drawing to `rect` until clip_end.
clip_begin :: proc(r: ^Renderer, rect: Rect) {
	flush(r)
	gl.Enable(gl.SCISSOR_TEST)
	gl.Scissor(i32(rect.x), i32(r.screen.y - rect.y - rect.h), i32(rect.w), i32(rect.h))
}

clip_end :: proc(r: ^Renderer) {
	flush(r)
	gl.Disable(gl.SCISSOR_TEST)
}

draw_rect :: proc(r: ^Renderer, rect: Rect, color: Color) {
	use(r, .Alpha_Texture, r.font_texture)
	// The centre of fontstash's white 2x2 block at the atlas origin.
	u := 1 / f32(r.fonts.width)
	v := 1 / f32(r.fonts.height)
	push_quad(r, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, u, v, u, v, color)
}

// A straight stroke `width` pixels wide from (x0, y0) to (x1, y1), with square ends
// that reach half the width past each point (so strokes meeting at a point join).
// Its long edges fade out over a pixel, so diagonals stay smooth.
draw_line :: proc(r: ^Renderer, x0, y0, x1, y1, width: f32, color: Color) {
	dx, dy := x1 - x0, y1 - y0
	length := math.sqrt(dx * dx + dy * dy)
	if length == 0 {
		return
	}
	use(r, .Alpha_Texture, r.font_texture)
	u := 1 / f32(r.fonts.width)
	v := 1 / f32(r.fonts.height)
	along := [2]f32{dx, dy} / length
	across := [2]f32{-along.y, along.x}
	half := width / 2
	a := [2]f32{x0, y0} - along * half
	b := [2]f32{x1, y1} + along * half
	faded := Color{color.r, color.g, color.b, 0}
	inner := max(half - 0.5, 0)
	outer := half + 0.5
	// The solid middle, then a strip on each side fading to clear.
	push_strip(r, a + across * inner, b + across * inner, b - across * inner, a - across * inner, color, color, u, v)
	push_strip(r, a + across * outer, b + across * outer, b + across * inner, a + across * inner, faded, color, u, v)
	push_strip(r, a - across * inner, b - across * inner, b - across * outer, a - across * outer, color, faded, u, v)
}

// Two triangles from four corners in order; the first two corners get `first`,
// the last two `second`.
@(private = "file")
push_strip :: proc(r: ^Renderer, p0, p1, p2, p3: [2]f32, first, second: Color, u, v: f32) {
	append(
		&r.vertices,
		Vertex{p0, {u, v}, first},
		Vertex{p1, {u, v}, first},
		Vertex{p2, {u, v}, second},
		Vertex{p0, {u, v}, first},
		Vertex{p2, {u, v}, second},
		Vertex{p3, {u, v}, second},
	)
}

draw_image :: proc(r: ^Renderer, texture: u32, rect: Rect, tint := Color{255, 255, 255, 255}) {
	use(r, .Rgba_Texture, texture)
	push_quad(r, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, 0, 0, 1, 1, tint)
}

// Draws part of a texture, `uv` as (u0, v0, u1, v1), into `rect`.
draw_image_part :: proc(r: ^Renderer, texture: u32, rect: Rect, uv: [4]f32) {
	use(r, .Rgba_Texture, texture)
	push_quad(r, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, uv[0], uv[1], uv[2], uv[3], {255, 255, 255, 255})
}

@(private = "file")
set_font :: proc(r: ^Renderer, font: Font, size: f32) {
	fs.SetFont(&r.fonts, r.font_ids[font])
	fs.SetSize(&r.fonts, size * r.text_scale)
}

// Draws text with its top at y. Returns the x after the text.
draw_text :: proc(r: ^Renderer, font: Font, size: f32, x, y: f32, text: string, color: Color) -> f32 {
	use(r, .Alpha_Texture, r.font_texture)
	set_font(r, font, size)
	iter := fs.TextIterInit(&r.fonts, x, y, visible_text(text))
	quad: fs.Quad
	for fs.TextIterNext(&r.fonts, &iter, &quad) {
		// Glyphs are rasterized unhinted; drawn at fractional positions, the texture
		// filter smears them across two pixels. Whole pixels keep them sharp.
		dx := math.round(quad.x0) - quad.x0
		dy := math.round(quad.y0) - quad.y0
		push_quad(r, quad.x0 + dx, quad.y0 + dy, quad.x1 + dx, quad.y1 + dy, quad.s0, quad.t0, quad.s1, quad.t1, color)
	}
	return iter.nextx
}

text_width :: proc(r: ^Renderer, font: Font, size: f32, text: string) -> f32 {
	set_font(r, font, size)
	return fs.TextBounds(&r.fonts, visible_text(text))
}

// `text` without the invisible characters fonts would draw anyway: Noto Sans
// shows U+034F as a dotted box, and characters no font has show as boxes. Chat
// tools add U+034F or U+E0000 to repeat a message past Twitch's duplicate check.
// The same string when there are none, else allocated with the temp allocator.
visible_text :: proc(text: string) -> string {
	invisible :: proc(c: rune) -> bool {
		switch c {
		case 0x034F, 0x180E, 0x200B, 0x2060 ..= 0x2064, 0xFEFF, 0xE0000, 0xE0001:
			return true
		}
		return false
	}
	found := false
	for c in text {
		if invisible(c) {
			found = true
			break
		}
	}
	if !found {
		return text
	}
	sb := strings.builder_make(context.temp_allocator)
	for c in text {
		if !invisible(c) {
			strings.write_rune(&sb, c)
		}
	}
	return strings.to_string(sb)
}

line_height :: proc(r: ^Renderer, font: Font, size: f32) -> f32 {
	set_font(r, font, size)
	_, _, h := fs.VerticalMetrics(&r.fonts)
	return h
}
