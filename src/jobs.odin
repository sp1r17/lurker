package app

import "core:sync"
import "core:thread"
import sdl "vendor:sdl3"

JOB_WORKERS :: 4

// Background work: downloads and decoding. A job's `run` happens on a worker thread
// and must only touch the job; the main thread then takes it back with jobs_take and
// applies the results.
Job :: struct {
	run:     proc(job: ^Job),
	payload: Job_Payload,
}

Job_Payload :: union {
	Image_Job,
	Emote_Set_Job,
	Badges_Job,
}

Jobs :: struct {
	mutex:      sync.Mutex,
	cond:       sync.Cond,
	pending:    [dynamic]^Job,
	done:       [dynamic]^Job,
	stop:       bool,
	wake_event: u32,
	workers:    [JOB_WORKERS]^thread.Thread,
}

jobs_start :: proc(jobs: ^Jobs, wake_event: u32) {
	jobs.wake_event = wake_event
	for &w in jobs.workers {
		w = thread.create_and_start_with_poly_data(jobs, worker, context)
	}
}

// Waits for running jobs to finish. Jobs not taken are freed with `destroy_job`.
jobs_stop :: proc(jobs: ^Jobs) {
	{
		sync.guard(&jobs.mutex)
		jobs.stop = true
		sync.cond_broadcast(&jobs.cond)
	}
	for w in jobs.workers {
		thread.join(w)
		thread.destroy(w)
	}
	for job in jobs.pending {
		destroy_job(job)
	}
	for job in jobs.done {
		destroy_job(job)
	}
	delete(jobs.pending)
	delete(jobs.done)
}

// Queues a job; the jobs system owns it until jobs_take hands it back.
jobs_add :: proc(jobs: ^Jobs, run: proc(job: ^Job), payload: Job_Payload) {
	job := new(Job)
	job^ = {run, payload}
	sync.guard(&jobs.mutex)
	append(&jobs.pending, job)
	sync.cond_signal(&jobs.cond)
}

// Moves finished jobs onto the end of `into`. The caller owns them.
jobs_take :: proc(jobs: ^Jobs, into: ^[dynamic]^Job) {
	sync.guard(&jobs.mutex)
	append(into, ..jobs.done[:])
	clear(&jobs.done)
}

@(private = "file")
worker :: proc(jobs: ^Jobs) {
	for {
		job: ^Job
		{
			sync.guard(&jobs.mutex)
			for len(jobs.pending) == 0 && !jobs.stop {
				sync.cond_wait(&jobs.cond, &jobs.mutex)
			}
			if jobs.stop {
				return
			}
			job = pop_front(&jobs.pending)
		}

		job.run(job)
		free_all(context.temp_allocator)

		{
			sync.guard(&jobs.mutex)
			append(&jobs.done, job)
		}
		e: sdl.Event
		e.type = sdl.EventType(jobs.wake_event)
		// Fails only when SDL's event queue is full; the next job pushes again.
		_ = sdl.PushEvent(&e)
	}
}

destroy_job :: proc(job: ^Job) {
	switch &p in job.payload {
	case Image_Job:
		destroy_image_job(&p)
	case Emote_Set_Job:
		destroy_emote_set_job(&p)
	case Badges_Job:
		destroy_badges_job(&p)
	}
	free(job)
}
