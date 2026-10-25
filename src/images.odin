package app

import "core:log"
import "core:strings"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

// GIFs with a 0 or tiny frame delay are shown at 10 fps, as browsers do.
MIN_FRAME_DELAY_MS :: 20
DEFAULT_FRAME_DELAY_MS :: 100

// Images in the disk cache that go this long without being drawn are evicted:
// their textures are freed, and they're read back from the cache when next drawn.
IMAGE_IDLE_MS :: 5 * 60_000
// How often images_evict looks for idle images.
IMAGE_EVICT_EVERY_MS :: 30_000

Image_State :: enum {
	Loading,
	Ready,
	Failed,
	// Its textures freed for going unused. image_get and image_use load it again,
	// so callers never see this.
	Evicted,
}

Image_Frame :: struct {
	texture: u32,
	// When this frame stops showing, in ms from the start of the animation.
	end_ms:  int,
}

// A downloaded emote or badge. Owned by Images; the pointer stays valid until
// images_destroy (or image_release), evicted or not.
Image :: struct {
	state:       Image_State,
	// Its key in Images.by_url, not separately owned.
	url:         string,
	// Whether it's in the disk cache, and so can be evicted and read back.
	cache:       bool,
	// Image pixels per logical pixel: 2 for a 2x image fetched for a high-DPI screen.
	pixel_scale: f32,
	// In logical pixels; kept through eviction, so nothing moves when it's
	// evicted or reloaded.
	size:        [2]f32,
	frames:      [dynamic]Image_Frame,
	duration_ms: int,
	// Released while still downloading: freed when the download finishes.
	orphaned:    bool,
	// Whether it's been drawn since images_evict last looked, and how many of its
	// looks in a row found it not drawn.
	used:        bool,
	idle_looks:  int,
}

// Every image by URL, each downloaded once. `version` goes up whenever an image
// finishes loading with a new size (or fails), since that changes the chat layout.
//
// Images go unused when their chat is scrolled away or left, but drivers can keep
// a copy of each texture in RAM (NVIDIA does, mipmaps included), so images_evict
// frees idle ones; otherwise a long session in an emote-heavy chat would grow by a
// few hundred MB.
Images :: struct {
	by_url:     map[string]^Image,
	version:    int,
	// When images_evict last looked (Assets.now_ms).
	last_evict: int,
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
	free_textures(image)
	delete(image.frames)
	free(image)
}

@(private = "file")
free_textures :: proc(image: ^Image) {
	for f in image.frames {
		tex := f.texture
		gl.DeleteTextures(1, &tex)
	}
	clear(&image.frames)
}

// Forgets the image for `url`, for images that are replaced over time (stream
// thumbnails). Pointers to it become invalid.
image_release :: proc(images: ^Images, url: string) {
	key, image := delete_key(&images.by_url, url)
	if image == nil {
		return
	}
	delete(key)
	image.url = ""
	if image.state == .Loading {
		image.orphaned = true
	} else {
		free_image(image)
	}
}

// Returns the image for `url`, starting its download the first time it's asked for.
// `cache` keeps it on disk for later runs: only for URLs whose image never changes.
image_get :: proc(images: ^Images, jobs: ^Jobs, url: string, pixel_scale: f32, cache := true) -> ^Image {
	if image, ok := images.by_url[url]; ok {
		image_use(jobs, image)
		return image
	}
	image := new(Image)
	image.url = strings.clone(url)
	image.cache = cache
	image.pixel_scale = pixel_scale
	image.used = true
	images.by_url[image.url] = image
	jobs_add(jobs, run_image_job, Image_Job{url = strings.clone(url), image = image, cache = cache})
	return image
}

// Marks an image as drawn, loading it again if it was evicted. image_get does
// this; it's for images kept from an earlier image_get (a chat line's layout).
image_use :: proc(jobs: ^Jobs, image: ^Image) {
	image.used = true
	if image.state == .Evicted {
		image.state = .Loading
		jobs_add(jobs, run_image_job, Image_Job{url = strings.clone(image.url), image = image, cache = true})
	}
}

// Every IMAGE_EVICT_EVERY_MS, frees the textures of images in the disk cache
// that haven't been drawn for IMAGE_IDLE_MS. Call after drawing.
images_evict :: proc(images: ^Images, now_ms: int) {
	if now_ms - images.last_evict < IMAGE_EVICT_EVERY_MS {
		return
	}
	images.last_evict = now_ms
	evicted := 0
	for _, image in images.by_url {
		if image.used {
			image.used = false
			image.idle_looks = 0
			continue
		}
		image.idle_looks += 1
		if image.state == .Ready && image.cache && image.idle_looks * IMAGE_EVICT_EVERY_MS >= IMAGE_IDLE_MS {
			free_textures(image)
			image.state = .Evicted
			evicted += 1
		}
	}
	if evicted > 0 {
		log.debugf("evicted %d idle images", evicted)
	}
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
	cache:  bool,
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
	res: Http_Response
	from_cache, ok: bool
	if p.cache {
		res, from_cache, ok = cached_get(p.url)
	} else {
		res, ok = http_request(p.url, allocator = context.temp_allocator)
	}
	if !ok {
		return
	}
	if res.status != 200 {
		log.warnf("image %s: HTTP %d", p.url, res.status)
		return
	}
	anim := img.LoadAnimation_IO(sdl.IOFromConstMem(raw_data(res.body), uint(len(res.body))), true)
	if anim == nil && from_cache {
		// A damaged cached copy: drop it and download again.
		cache_forget(p.url)
		res, _, ok = cached_get(p.url)
		if ok && res.status == 200 {
			anim = img.LoadAnimation_IO(sdl.IOFromConstMem(raw_data(res.body), uint(len(res.body))), true)
		}
	}
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
	size := [2]f32{f32(p.size.x), f32(p.size.y)} / image.pixel_scale
	end: int
	for f in p.frames {
		tex: u32
		gl.GenTextures(1, &tex)
		gl.BindTexture(gl.TEXTURE_2D, tex)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, p.size.x, p.size.y, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(f.pixels))
		// Mipmaps keep images drawn well below their size (64 px emoji at text
		// height, 2x emotes) smooth instead of grainy.
		gl.GenerateMipmap(gl.TEXTURE_2D)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		end += f.delay_ms
		append(&image.frames, Image_Frame{tex, end})
	}
	image.duration_ms = end
	image.state = .Ready
	// Read back after eviction, it's the same size, and the layout stands.
	if image.size != size {
		image.size = size
		images.version += 1
	}
}
