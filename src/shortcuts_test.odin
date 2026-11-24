package app

import "core:strings"
import "core:testing"

// The list in the app and the README's table say the same, row for row.
@(test)
shortcuts_match_the_readme :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	readme := #load("../README.md", string)
	start := strings.index(readme, "| Key | Action |")
	testing.expect(t, start >= 0)
	rows := make([dynamic]Shortcut, context.temp_allocator)
	for line in strings.split_lines(readme[start:], context.temp_allocator)[2:] {
		if !strings.has_prefix(line, "| ") {
			break
		}
		cells := strings.split(strings.trim(line, "| "), " | ", context.temp_allocator)
		if len(cells) == 2 {
			append(&rows, Shortcut{cells[0], cells[1]})
		}
	}
	list := SHORTCUTS
	testing.expect_value(t, len(rows), len(list))
	for s, i in list {
		if i < len(rows) {
			testing.expect_value(t, rows[i], s)
		}
	}
}
