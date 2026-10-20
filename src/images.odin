package app

import "core:log"
import "core:strings"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

// GIFs with a 0 or tiny frame delay are shown at 10 fps, as browsers do.
MIN_FRAME_DELAY_MS :: 20
DEFAULT_FRAME_DELAY_MS :: 100

Image_State :: enum {
	Loading,
	Ready,
	Failed,
}

Image_Frame :: struct {
	texture: u32,
	// When this frame stops showing, in ms from the start of the animation.
	end_ms:  int,
}

// A downloaded emote or badge. Owned by Images; the pointer stays valid until
// images_destroy.
Image :: struct {
	state:       Image_State,
	// Image pixels per logical pixel: 2 for a 2x image fetched for a high-DPI screen.
	pixel_scale: f32,
	// In logical pixels.
	size:        [2]f32,
	frames:      [dynamic]Image_Frame,
	duration_ms: int,
	// Released while still downloading: freed when the download finishes.
	orphaned:    bool,
}

// Every image by URL, each downloaded once. `version` goes up whenever an image
// finishes loading, since that can change its size and so the chat layout.
Images :: struct {
	by_url:  map[string]^Image,
	version: int,
}

images_destroy :: proc(images: ^Images) {
	// Call after jobs_stop: unfinished jobs point at loading images.
	for url, image in images.by_url {
		free_image(image)
		delete(url)
	}
	delete(images.by_url)
}

@(private = "file")
free_image :: proc(image: ^Image) {
	for f in image.frames {
		tex := f.texture
		gl.DeleteTextures(1, &tex)
	}
	delete(image.frames)
	free(image)
}

// Forgets the image for `url`, for images that are replaced over time (stream
// thumbnails). Pointers to it become invalid.
image_release :: proc(images: ^Images, url: string) {
	key, image := delete_key(&images.by_url, url)
	if image == nil {
		return
	}
	delete(key)
	if image.state == .Loading {
		image.orphaned = true
	} else {
		free_image(image)
	}
}

// Returns the image for `url`, starting its download the first time it's asked for.
image_get :: proc(images: ^Images, jobs: ^Jobs, url: string, pixel_scale: f32) -> ^Image {
	if image, ok := images.by_url[url]; ok {
		return image
	}
	image := new(Image)
	image.pixel_scale = pixel_scale
	images.by_url[strings.clone(url)] = image
	jobs_add(jobs, run_image_job, Image_Job{url = strings.clone(url), image = image})
	return image
}

// The frame to show `now_ms` into the animation, and how long until the next one
// (-1 if the image doesn't animate).
image_frame :: proc(image: ^Image, now_ms: int) -> (texture: u32, next_change_ms: int) {
	if len(image.frames) <= 1 {
		return image.frames[0].texture if len(image.frames) == 1 else 0, -1
	}
	t := now_ms % image.duration_ms
	for f in image.frames {
		if t < f.end_ms {
			return f.texture, f.end_ms - t
		}
	}
	return image.frames[0].texture, 1
}

Decoded_Frame :: struct {
	// RGBA, row after row with no padding.
	pixels:   []u8,
	delay_ms: int,
}

Image_Job :: struct {
	url:    string,
	// Only for the main thread; the worker leaves it alone.
	image:  ^Image,
	ok:     bool,
	size:   [2]i32,
	frames: [dynamic]Decoded_Frame,
}

destroy_image_job :: proc(p: ^Image_Job) {
	// A released image waiting on this job has nobody else to free it. It has no
	// textures yet, so this needs no GL.
	if p.image.orphaned {
		free_image(p.image)
	}
	for f in p.frames {
		delete(f.pixels)
	}
	delete(p.frames)
	delete(p.url)
}

// On a worker: download and decode every frame.
@(private = "file")
run_image_job :: proc(job: ^Job) {
	p := &job.payload.(Image_Job)
	res, ok := http_request(p.url, allocator = context.temp_allocator)
	if !ok {
		return
	}
	if res.status != 200 {
		log.warnf("image %s: HTTP %d", p.url, res.status)
		return
	}
	anim := img.LoadAnimation_IO(sdl.IOFromConstMem(raw_data(res.body), uint(len(res.body))), true)
	if anim == nil {
		log.warnf("image %s: can't decode: %s", p.url, sdl.GetError())
		return
	}
	defer img.FreeAnimation(anim)

	p.size = {anim.w, anim.h}
	for i in 0 ..< int(anim.count) {
		frame := anim.frames[i]
		if frame.format != .RGBA32 {
			frame = sdl.ConvertSurface(frame, .RGBA32)
			if frame == nil {
				return
			}
		}
		defer if frame != anim.frames[i] {
			sdl.DestroySurface(frame)
		}
		if frame.w != anim.w || frame.h != anim.h {
			return
		}

		row := int(frame.w) * 4
		pixels := make([]u8, row * int(frame.h))
		src := ([^]u8)(frame.pixels)
		for y in 0 ..< int(frame.h) {
			copy(pixels[y * row:][:row], src[y * int(frame.pitch):][:row])
		}
		delay := int(anim.delays[i])
		append(&p.frames, Decoded_Frame{pixels, delay if delay >= MIN_FRAME_DELAY_MS else DEFAULT_FRAME_DELAY_MS})
	}
	p.ok = len(p.frames) > 0
}

// On the main thread: upload the frames.
finish_image_job :: proc(images: ^Images, p: ^Image_Job) {
	image := p.image
	if image.orphaned {
		// Freed by destroy_job.
		return
	}
	if !p.ok {
		image.state = .Failed
		images.version += 1
		return
	}
	end: int
	for f in p.frames {
		tex: u32
		gl.GenTextures(1, &tex)
		gl.BindTexture(gl.TEXTURE_2D, tex)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, p.size.x, p.size.y, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(f.pixels))
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		end += f.delay_ms
		append(&image.frames, Image_Frame{tex, end})
	}
	image.duration_ms = end
	image.size = {f32(p.size.x), f32(p.size.y)} / image.pixel_scale
	image.state = .Ready
	images.version += 1
}
