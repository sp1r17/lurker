package app

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "vendor:curl"

@(private = "file")
be32 :: proc(b: ^bytes.Buffer, v: int) {
	bytes.buffer_write(b, {u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)})
}

@(private = "file")
le16 :: proc(b: ^bytes.Buffer, v: int) {
	bytes.buffer_write(b, {u8(v), u8(v >> 8)})
}

@(private = "file")
le32 :: proc(b: ^bytes.Buffer, v: int) {
	bytes.buffer_write(b, {u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)})
}

// A PNG's signature and IHDR, and an acTL when `frames` > 0. CRCs are zero:
// only the decoder checks them.
@(private = "file")
png :: proc(w, h: int, frames := 0) -> []byte {
	b: bytes.Buffer
	bytes.buffer_write_string(&b, "\x89PNG\r\n\x1a\n")
	be32(&b, 13)
	bytes.buffer_write_string(&b, "IHDR")
	be32(&b, w)
	be32(&b, h)
	bytes.buffer_write(&b, {8, 6, 0, 0, 0})
	be32(&b, 0)
	if frames > 0 {
		be32(&b, 8)
		bytes.buffer_write_string(&b, "acTL")
		be32(&b, frames)
		be32(&b, 0)
		be32(&b, 0)
	}
	be32(&b, 0)
	bytes.buffer_write_string(&b, "IDAT")
	be32(&b, 0)
	return bytes.buffer_to_bytes(&b)
}

// A GIF whose screen is w × h, with `frames` frames of fw × fh.
@(private = "file")
gif :: proc(w, h, frames: int, fw := 0, fh := 0) -> []byte {
	b: bytes.Buffer
	bytes.buffer_write_string(&b, "GIF89a")
	le16(&b, w)
	le16(&b, h)
	bytes.buffer_write(&b, {0, 0, 0})
	for _ in 0 ..< frames {
		// A graphic control extension, then the frame with one byte of data.
		bytes.buffer_write(&b, {0x21, 0xf9, 4, 0, 10, 0, 0, 0})
		bytes.buffer_write(&b, {0x2c, 0, 0, 0, 0})
		le16(&b, fw if fw > 0 else w)
		le16(&b, fh if fh > 0 else h)
		bytes.buffer_write(&b, {0, 2, 1, 0, 0})
	}
	bytes.buffer_write(&b, {0x3b})
	return bytes.buffer_to_bytes(&b)
}

// A lossless WebP of w × h.
@(private = "file")
webp_lossless :: proc(w, h: int) -> []byte {
	b: bytes.Buffer
	bytes.buffer_write_string(&b, "RIFF")
	le32(&b, 4 + 8 + 6)
	bytes.buffer_write_string(&b, "WEBPVP8L")
	le32(&b, 5)
	bytes.buffer_write(&b, {0x2f})
	le32(&b, (w - 1) | (h - 1) << 14)
	bytes.buffer_write(&b, {0})
	return bytes.buffer_to_bytes(&b)
}

// An animated WebP with a w × h canvas and `frames` (empty) frames.
@(private = "file")
webp_animated :: proc(w, h, frames: int) -> []byte {
	b: bytes.Buffer
	bytes.buffer_write_string(&b, "RIFF")
	le32(&b, 0)
	bytes.buffer_write_string(&b, "WEBPVP8X")
	le32(&b, 10)
	bytes.buffer_write(&b, {0x02, 0, 0, 0})
	bytes.buffer_write(&b, {u8(w - 1), u8((w - 1) >> 8), u8((w - 1) >> 16)})
	bytes.buffer_write(&b, {u8(h - 1), u8((h - 1) >> 8), u8((h - 1) >> 16)})
	for _ in 0 ..< frames {
		bytes.buffer_write_string(&b, "ANMF")
		le32(&b, 0)
	}
	return bytes.buffer_to_bytes(&b)
}

// A JPEG with an APP0 segment, then a baseline start of frame.
@(private = "file")
jpeg :: proc(w, h: int) -> []byte {
	b: bytes.Buffer
	bytes.buffer_write(&b, {0xff, 0xd8, 0xff, 0xe0, 0, 16})
	bytes.buffer_write_string(&b, "JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")
	bytes.buffer_write(&b, {0xff, 0xc0, 0, 17, 8, u8(h >> 8), u8(h), u8(w >> 8), u8(w)})
	return bytes.buffer_to_bytes(&b)
}

@(private = "file")
expect_header :: proc(t: ^testing.T, data: []byte, want: Image_Header, allowed: bool, loc := #caller_location) {
	defer delete(data)
	h, ok := read_image_header(data)
	testing.expect(t, ok, "unreadable", loc = loc)
	testing.expect_value(t, h, want, loc = loc)
	testing.expect_value(t, image_header_allowed(h), allowed, loc = loc)
}

@(test)
image_headers_are_read :: proc(t: ^testing.T) {
	expect_header(t, png(112, 112), {112, 112, 1}, true)
	expect_header(t, png(256, 128, frames = 60), {256, 128, 60}, true)
	expect_header(t, gif(112, 112, 3), {112, 112, 3}, true)
	expect_header(t, webp_lossless(56, 28), {56, 28, 1}, true)
	expect_header(t, webp_animated(128, 128, 40), {128, 128, 40}, true)
	expect_header(t, jpeg(1920, 1080), {1920, 1080, 1}, true)
}

// Small files that would decode to gigabytes.
@(test)
image_bombs_are_refused :: proc(t: ^testing.T) {
	expect_header(t, png(60000, 60000), {60000, 60000, 1}, false)
	expect_header(t, png(1024, 1024, frames = 100_000), {1024, 1024, 100_000}, false)
	expect_header(t, webp_animated(16384, 16384, 1), {16384, 16384, 1}, false)
	expect_header(t, jpeg(65535, 65535), {65535, 65535, 1}, false)
	// The screen is small, but a frame is as big as a GIF allows.
	expect_header(t, gif(16, 16, 1, fw = 65535, fh = 65535), {65535, 65535, 1}, false)
	// Within the side limit, but too many frames: counting stops once it's over.
	big := gif(2048, 2048, 20)
	defer delete(big)
	h, ok := read_image_header(big)
	testing.expect(t, ok && !image_header_allowed(h) && h.frames < 20)
}

@(test)
unreadable_images_are_refused :: proc(t: ^testing.T) {
	cases := [?]string{"", "\x89PNG", "GIF89a\x10", "RIFF\x00\x00\x00\x00WEBP", "\xff\xd8\xff", "<html>not an image</html>", "BM\x00\x00"}
	for c in cases {
		_, ok := read_image_header(transmute([]byte)c)
		testing.expectf(t, !ok, "read %q", c)
	}
	// Cut short anywhere before its size.
	full := jpeg(640, 480)
	defer delete(full)
	for n in 0 ..< len(full) - 4 {
		_, ok := read_image_header(full[:n])
		testing.expectf(t, !ok, "read %d bytes", n)
	}
}

// A response bigger than allowed fails the request instead of filling memory.
@(test)
downloads_are_limited :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	curl.global_init(curl.GLOBAL_DEFAULT)
	defer curl.global_cleanup()
	tmp, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil)
	path := fmt.tprintf("%s/lurker-limit-test-%d", tmp, time.now()._nsec)
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, make([]byte, 64 * 1024, context.temp_allocator)) == nil)
	slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	url := fmt.tprintf("file://%s%s", "" if strings.has_prefix(slashed, "/") else "/", slashed)

	res, ok := http_request(url, allocator = context.temp_allocator, max_bytes = 64 * 1024)
	testing.expect(t, ok)
	testing.expect_value(t, len(res.body), 64 * 1024)
	_, too_big := http_request(url, allocator = context.temp_allocator, max_bytes = 16 * 1024)
	testing.expect(t, !too_big)
}
