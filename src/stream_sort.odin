package app

import "core:slice"
import "core:strings"

// How the stream lists (Following, Top, a category) are ordered (Layout.stream_sort).
Stream_Sort :: enum {
	Viewers,
	// Most recently started first.
	Started,
	Name,
	Category,
}

@(rodata)
STREAM_SORT_LABELS := [Stream_Sort]string {
	.Viewers  = "Viewers",
	.Started  = "Recently started",
	.Name     = "Name",
	.Category = "Category",
}

// Orders `l`'s streams, and their thumbnails with them, by `by`; ties keep
// Twitch's order (most viewers first).
stream_list_sort :: proc(l: ^Stream_List, by: Stream_Sort) {
	n := len(l.streams)
	order := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		order[i] = i
	}
	Sorter :: struct {
		streams: []Stream,
		by:      Stream_Sort,
	}
	sorter := Sorter{l.streams[:], by}
	context.user_ptr = &sorter
	slice.stable_sort_by(order, proc(a, b: int) -> bool {
		s := (^Sorter)(context.user_ptr)
		x, y := s.streams[a], s.streams[b]
		switch s.by {
		case .Viewers:
			return x.viewer_count > y.viewer_count
		case .Started:
			// RFC 3339 in UTC sorts as text.
			return x.started_at > y.started_at
		case .Name:
			return strings.compare(strings.to_lower(x.user_name, context.temp_allocator), strings.to_lower(y.user_name, context.temp_allocator)) < 0
		case .Category:
			return strings.compare(strings.to_lower(x.game_name, context.temp_allocator), strings.to_lower(y.game_name, context.temp_allocator)) < 0
		}
		return false
	})
	streams := slice.clone(l.streams[:], context.temp_allocator)
	for i, at in order {
		l.streams[at] = streams[i]
	}
	if len(l.thumbnails) == n {
		thumbnails := slice.clone(l.thumbnails[:], context.temp_allocator)
		for i, at in order {
			l.thumbnails[at] = thumbnails[i]
		}
	}
}
