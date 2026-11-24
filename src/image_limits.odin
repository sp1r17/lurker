package app

// Images come from anyone: emotes are uploaded to 7TV, BTTV and FFZ by their
// users. A file of a few KB can declare a picture of 60000 × 60000 pixels, or
// thousands of animation frames, and decoding it would take gigabytes. So each
// image's size is read from its header first, without decoding anything, and
// one too big isn't decoded at all.

// The most an image download can be. The largest Lurker shows are a few hundred
// KB (animated emotes, the seek bar's preview sheets).
IMAGE_MAX_BYTES :: 16 * 1024 * 1024
// The widest or tallest an image (or one of its frames) can be.
IMAGE_MAX_SIDE :: 8192
// The most memory an image's decoded frames can take, at 4 bytes a pixel.
IMAGE_MAX_DECODED_BYTES :: 128 * 1024 * 1024

Image_Header :: struct {
	width, height: int,
	// 1 for a still image.
	frames:        int,
}

// Whether an image of this size may be decoded.
image_header_allowed :: proc(h: Image_Header) -> bool {
	if h.width <= 0 || h.height <= 0 || h.frames <= 0 {
		return false
	}
	if h.width > IMAGE_MAX_SIDE || h.height > IMAGE_MAX_SIDE {
		return false
	}
	return h.width * h.height * 4 * h.frames <= IMAGE_MAX_DECODED_BYTES
}

// The size and frame count `data` declares, for the formats Lurker shows: PNG
// (animated too), GIF, WebP and JPEG. False for anything else, or a header too
// short or malformed to read.
read_image_header :: proc(data: []byte) -> (h: Image_Header, ok: bool) {
	switch {
	case has_bytes(data, 0, "\x89PNG\r\n\x1a\n"):
		return png_header(data)
	case has_bytes(data, 0, "GIF87a"), has_bytes(data, 0, "GIF89a"):
		return gif_header(data)
	case has_bytes(data, 0, "RIFF") && has_bytes(data, 8, "WEBP"):
		return webp_header(data)
	case has_bytes(data, 0, "\xff\xd8"):
		return jpeg_header(data)
	}
	return {}, false
}

@(private = "file")
has_bytes :: proc(data: []byte, at: int, s: string) -> bool {
	return at + len(s) <= len(data) && string(data[at:][:len(s)]) == s
}

@(private = "file")
u16_be :: proc(d: []byte, at: int) -> (int, bool) {
	if at < 0 || at + 2 > len(d) {
		return 0, false
	}
	return int(d[at]) << 8 | int(d[at + 1]), true
}

@(private = "file")
u16_le :: proc(d: []byte, at: int) -> (int, bool) {
	if at < 0 || at + 2 > len(d) {
		return 0, false
	}
	return int(d[at]) | int(d[at + 1]) << 8, true
}

@(private = "file")
u24_le :: proc(d: []byte, at: int) -> (int, bool) {
	if at < 0 || at + 3 > len(d) {
		return 0, false
	}
	return int(d[at]) | int(d[at + 1]) << 8 | int(d[at + 2]) << 16, true
}

@(private = "file")
u32_be :: proc(d: []byte, at: int) -> (int, bool) {
	if at < 0 || at + 4 > len(d) {
		return 0, false
	}
	return int(d[at]) << 24 | int(d[at + 1]) << 16 | int(d[at + 2]) << 8 | int(d[at + 3]), true
}

@(private = "file")
u32_le :: proc(d: []byte, at: int) -> (int, bool) {
	if at < 0 || at + 4 > len(d) {
		return 0, false
	}
	return int(d[at]) | int(d[at + 1]) << 8 | int(d[at + 2]) << 16 | int(d[at + 3]) << 24, true
}

// IHDR, which comes first, has the size; an animated PNG's acTL, before the
// image data, has the frame count.
@(private = "file")
png_header :: proc(d: []byte) -> (h: Image_Header, ok: bool) {
	if !has_bytes(d, 12, "IHDR") {
		return {}, false
	}
	h.width = u32_be(d, 16) or_return
	h.height = u32_be(d, 20) or_return
	h.frames = 1
	at := 8
	for at + 8 <= len(d) {
		length := u32_be(d, at) or_return
		if has_bytes(d, at + 4, "IDAT") || has_bytes(d, at + 4, "IEND") {
			break
		}
		if has_bytes(d, at + 4, "acTL") {
			h.frames = u32_be(d, at + 8) or_return
			break
		}
		// Length, type, data and CRC.
		at += 12 + length
	}
	return h, true
}

// The logical screen's size, and an image descriptor per frame, each followed by
// its data in sub-blocks. A frame larger than the screen makes the image as
// large as that frame.
@(private = "file")
gif_header :: proc(d: []byte) -> (h: Image_Header, ok: bool) {
	h.width = u16_le(d, 6) or_return
	h.height = u16_le(d, 8) or_return
	if len(d) < 13 {
		return {}, false
	}
	at := 13
	if d[10] & 0x80 != 0 {
		at += 3 << (uint(d[10] & 7) + 1)
	}
	// Past a run of data sub-blocks (each its length, then that many bytes),
	// ended by an empty one.
	skip_blocks :: proc(d: []byte, at: int) -> (int, bool) {
		at := at
		for at < len(d) {
			n := int(d[at])
			at += 1 + n
			if n == 0 {
				return at, true
			}
		}
		return at, false
	}
	for at < len(d) {
		switch d[at] {
		case 0x3b:
			return h, h.frames > 0
		case 0x21:
			// An extension: its label, then its data.
			at = skip_blocks(d, at + 2) or_return
		case 0x2c:
			w := u16_le(d, at + 5) or_return
			fh := u16_le(d, at + 7) or_return
			if at + 9 >= len(d) {
				return {}, false
			}
			flags := d[at + 9]
			h.width, h.height = max(h.width, w), max(h.height, fh)
			h.frames += 1
			at += 10
			if flags & 0x80 != 0 {
				at += 3 << (uint(flags & 7) + 1)
			}
			// The LZW code size, then the image data.
			at = skip_blocks(d, at + 1) or_return
			if !image_header_allowed(h) {
				// No need to count the rest.
				return h, true
			}
		case:
			return {}, false
		}
	}
	// Cut short: what's there is all that would decode.
	return h, h.frames > 0
}

// Chunks after the 12-byte RIFF header, each a four-letter type, a size and
// that much data, padded to an even length. VP8X has an extended image's canvas
// size, and ANMF each of an animation's frames; VP8L and VP8 a simple image's.
@(private = "file")
webp_header :: proc(d: []byte) -> (h: Image_Header, ok: bool) {
	at := 12
	for at + 8 <= len(d) {
		size := u32_le(d, at + 4) or_return
		data := at + 8
		switch {
		case has_bytes(d, at, "VP8X"):
			h.width = (u24_le(d, data + 4) or_return) + 1
			h.height = (u24_le(d, data + 7) or_return) + 1
		case has_bytes(d, at, "ANMF"):
			h.frames += 1
			if h.width > 0 && !image_header_allowed(h) {
				return h, true
			}
		case has_bytes(d, at, "VP8L") && h.width == 0:
			if data >= len(d) || d[data] != 0x2f {
				return {}, false
			}
			bits := u32_le(d, data + 1) or_return
			h.width, h.height, h.frames = bits & 0x3fff + 1, (bits >> 14) & 0x3fff + 1, 1
			return h, true
		case has_bytes(d, at, "VP8 ") && h.width == 0:
			if !has_bytes(d, data + 3, "\x9d\x01\x2a") {
				return {}, false
			}
			h.width = (u16_le(d, data + 6) or_return) & 0x3fff
			h.height = (u16_le(d, data + 8) or_return) & 0x3fff
			h.frames = 1
			return h, true
		}
		at = data + size + (size & 1)
	}
	if h.width == 0 {
		return {}, false
	}
	h.frames = max(h.frames, 1)
	return h, true
}

// Markers, each 0xff and a type, most with a length after; a start-of-frame
// marker (0xc0 to 0xcf, but for 0xc4, 0xc8 and 0xcc) has the size.
@(private = "file")
jpeg_header :: proc(d: []byte) -> (h: Image_Header, ok: bool) {
	at := 2
	for at + 1 < len(d) {
		if d[at] != 0xff {
			return {}, false
		}
		marker := d[at + 1]
		switch {
		case marker == 0xff:
			// Fill bytes.
			at += 1
			continue
		case marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7):
			// No length.
			at += 2
			continue
		case marker == 0xda || marker == 0xd9:
			// The image data, or its end, with no size seen.
			return {}, false
		case marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc:
			h.height = u16_be(d, at + 5) or_return
			h.width = u16_be(d, at + 7) or_return
			h.frames = 1
			return h, true
		}
		length := u16_be(d, at + 2) or_return
		at += 2 + length
	}
	return {}, false
}
