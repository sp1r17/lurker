package app

import "core:testing"

// An image as if it had loaded, without textures (so no GL is needed).
@(private = "file")
add_ready_image :: proc(images: ^Images, jobs: ^Jobs, url: string, cache := true) -> ^Image {
	image := image_get(images, jobs, url, 1, cache)
	image.state = .Ready
	image.size = {28, 28}
	return image
}

@(private = "file")
drop_jobs :: proc(jobs: ^Jobs) {
	for job in jobs.pending {
		destroy_job(job)
	}
	clear(&jobs.pending)
}

@(test)
images_evict_idle :: proc(t: ^testing.T) {
	images: Images
	jobs: Jobs
	defer {
		drop_jobs(&jobs)
		delete(jobs.pending)
		images_destroy(&images)
	}
	drawn := add_ready_image(&images, &jobs, "https://x/drawn.png")
	idle := add_ready_image(&images, &jobs, "https://x/idle.png")
	thumbnail := add_ready_image(&images, &jobs, "https://x/thumb.jpg", cache = false)
	drop_jobs(&jobs)

	now := 0
	for now < IMAGE_IDLE_MS + 2 * IMAGE_EVICT_EVERY_MS {
		now += IMAGE_EVICT_EVERY_MS
		image_use(&jobs, drawn)
		images_evict(&images, now)
	}
	testing.expect_value(t, drawn.state, Image_State.Ready)
	testing.expect_value(t, idle.state, Image_State.Evicted)
	// Not in the disk cache: it would have to be downloaded again.
	testing.expect_value(t, thumbnail.state, Image_State.Ready)
	testing.expect_value(t, idle.size, [2]f32{28, 28})
	testing.expect_value(t, len(jobs.pending), 0)

	// Drawn again: read back from the cache.
	testing.expect(t, image_get(&images, &jobs, "https://x/idle.png", 1) == idle)
	testing.expect_value(t, idle.state, Image_State.Loading)
	testing.expect_value(t, len(jobs.pending), 1)
	p := jobs.pending[0].payload.(Image_Job)
	testing.expect_value(t, p.url, "https://x/idle.png")
	testing.expect(t, p.cache)

	// Released while being read back: the job frees it.
	image_release(&images, "https://x/idle.png")
	testing.expect(t, idle.orphaned)
}

@(test)
images_evict_waits :: proc(t: ^testing.T) {
	images: Images
	jobs: Jobs
	defer {
		drop_jobs(&jobs)
		delete(jobs.pending)
		images_destroy(&images)
	}
	image := add_ready_image(&images, &jobs, "https://x/a.png")
	// Looks closer together than IMAGE_EVICT_EVERY_MS don't count.
	for now in 1 ..= IMAGE_IDLE_MS {
		images_evict(&images, now)
	}
	testing.expect_value(t, image.state, Image_State.Ready)
	testing.expect_value(t, image.idle_looks, IMAGE_IDLE_MS / IMAGE_EVICT_EVERY_MS - 1)
}
