package app

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// Sizes in logical pixels, scaled by the display scale.
BROWSE_CARD_WIDTH :: 320
BROWSE_CATEGORY_WIDTH :: 150
BROWSE_GAP :: 16
BROWSE_PADDING :: 20
BROWSE_HEADER_HEIGHT :: 56
BROWSE_TITLE_SIZE :: 24
BROWSE_TAB_SIZE :: 20
BROWSE_CARD_TITLE_SIZE :: 17
BROWSE_CARD_TEXT_SIZE :: 16
BROWSE_SCROLL_STEP :: 80
BROWSE_SEARCH_WIDTH :: 300
// Search results are at most this wide, so names and titles stay near each other.
BROWSE_RESULTS_WIDTH :: 900
// Thumbnails are fetched at this size; Twitch scales them to order.
THUMBNAIL_SIZE :: [2]int{440, 248}
// Twitch refreshes thumbnails every few minutes; the list shown is checked every
// minute while browsing.
BROWSE_REFRESH_MS :: 60_000
// Categories change slowly, and refreshing them drops the pages loaded by
// scrolling, so they're refreshed less often.
CATEGORIES_REFRESH_MS :: 5 * 60_000
// Searching waits for typing to pause this long.
SEARCH_DELAY_MS :: 300

BROWSE_BACKGROUND :: Color{0x0e, 0x0e, 0x10, 255}
BROWSE_CARD_HOVER :: Color{0x26, 0x26, 0x2c, 255}
BROWSE_PLACEHOLDER :: Color{0x1f, 0x1f, 0x23, 255}
BROWSE_TEXT :: Color{0xef, 0xef, 0xf1, 255}
BROWSE_DIM_TEXT :: Color{0xad, 0xad, 0xb8, 255}
BROWSE_ACCENT :: Color{0xbf, 0x94, 0xff, 255}
LIVE_RED :: Color{0xeb, 0x04, 0x00, 255}
VIEWERS_BACKGROUND :: Color{0, 0, 0, 180}

Browse_State :: enum {
	// Nothing fetched yet.
	Empty,
	Loading,
	Loaded,
	Failed,
}

// What the browse screen shows. The first three are its tabs.
Browse_View :: enum {
	Following,
	Top,
	// All categories, most watched first; the Categories tab's first section.
	Categories,
	// The categories the user follows; the Categories tab's second section.
	Followed_Categories,
	// One category's live streams, opened from either section or a search.
	Category,
	// What the search box found: channels, or categories when searching from
	// Categories.
	Search,
}

Search_Kind :: enum {
	Channels,
	Categories,
}

BROWSE_TABS :: [?]Browse_View{.Following, .Top, .Categories}
BROWSE_TAB_LABELS := [Browse_View]string {
	.Following           = "Following",
	.Top                 = "Top",
	.Categories          = "Categories",
	.Followed_Categories = "",
	.Category            = "",
	.Search              = "",
}

// Live streams as a grid of cards: the followed channels, Twitch's top streams, or
// one category's.
Stream_List :: struct {
	state:         Browse_State,
	// Owned. Most viewers first.
	streams:       [dynamic]Stream,
	// Owned; each stream's thumbnail URL at the time it was fetched.
	thumbnails:    [dynamic]string,
	// Bumped on every refresh, so thumbnails are fetched anew.
	refresh_count: int,
	last_refresh:  int,
}

Browse :: struct {
	view:                 Browse_View,
	// Where Esc, or emptying the search box, goes back to from a search.
	back_view:            Browse_View,
	following, top:       Stream_List,
	// The category the Category view shows (owned), and its streams.
	category_id:          string,
	category_name:        string,
	category_viewers:     int,
	category:             Stream_List,
	// Owned; each most viewers first.
	categories_state:     Browse_State,
	categories_refreshed: int,
	followed_categories:  [dynamic]Category,
	top_categories:       [dynamic]Category,
	// Where the next page of top categories starts ("" when there are no more;
	// owned), and whether it's being fetched.
	categories_next:      string,
	more_categories:      bool,
	// The Categories tab's section shown last (Categories or Followed_Categories),
	// which the tab and a category's back button return to.
	categories_section:   Browse_View,
	// The search box; when it last changed; the query the results are for (owned).
	search:               Text_Input,
	search_box_scroll:    f32,
	search_edited:        int,
	search_query:         string,
	search_state:         Browse_State,
	// What the search is for, set when it starts from the view shown.
	search_kind:          Search_Kind,
	// Owned; channels or categories, as search_kind says.
	results:              [dynamic]Channel,
	category_results:     [dynamic]Category,
	// The columns of category results last drawn, for Up and Down.
	result_columns:       int,
	// The search row Enter opens; set when the arrow keys moved it, to scroll it
	// into view.
	selected:             int,
	reveal_selected:      bool,
	// The "/" that focused the search box, not to be typed into it.
	skip_slash:           bool,
	scroll:               [Browse_View]f32,
	max_scroll:           [Browse_View]f32,
	// Set while drawing, in pixels: each item of the view shown (cards, or search
	// rows), the tabs, the search box, the category's back button and the header.
	cards:                [dynamic]Rect,
	hovered:              int,
	tabs:                 [Browse_View]Rect,
	// The Categories tab's two section buttons.
	section_buttons:      [2]Rect,
	search_rect:          Rect,
	back_button:          Rect,
	header_h:             f32,
}

browse_destroy :: proc(b: ^Browse) {
	for l in ([]^Stream_List{&b.following, &b.top, &b.category}) {
		for s in l.streams {
			destroy_stream(s)
		}
		delete(l.streams)
		for url in l.thumbnails {
			delete(url)
		}
		delete(l.thumbnails)
	}
	delete(b.category_id)
	delete(b.category_name)
	for c in b.followed_categories {
		destroy_category(c)
	}
	delete(b.followed_categories)
	for c in b.top_categories {
		destroy_category(c)
	}
	delete(b.top_categories)
	delete(b.categories_next)
	for c in b.category_results {
		destroy_category(c)
	}
	delete(b.category_results)
	input_destroy(&b.search)
	delete(b.search_query)
	for c in b.results {
		destroy_channel(c)
	}
	delete(b.results)
	delete(b.cards)
}

// The stream list `view` shows, or nil if it doesn't show one.
browse_list :: proc(b: ^Browse, view: Browse_View) -> ^Stream_List {
	#partial switch view {
	case .Following:
		return &b.following
	case .Top:
		return &b.top
	case .Category:
		return &b.category
	}
	return nil
}

// Fetches what the view shown needs: its list if never fetched or older than
// BROWSE_REFRESH_MS, or the search once typing pauses. Returns ms until something
// is next due, for the main loop's wait.
browse_tick :: proc(app: ^App) -> (wait_ms: int) {
	b := &app.browse
	if !app.signed_in {
		return -1
	}
	now := app.assets.now_ms
	state: Browse_State
	refreshed: int
	switch b.view {
	case .Following, .Top, .Category:
		l := browse_list(b, b.view)
		state, refreshed = l.state, l.last_refresh
	case .Categories, .Followed_Categories:
		if b.categories_state == .Loading {
			return -1
		}
		due := b.categories_refreshed + CATEGORIES_REFRESH_MS
		if b.categories_state == .Empty || now >= due {
			browse_refresh(app)
			return -1
		}
		return due - now
	case .Search:
		if strings.trim_space(input_text(&b.search)) == b.search_query {
			return -1
		}
		due := b.search_edited + SEARCH_DELAY_MS
		if now >= due {
			search_start(app)
			return -1
		}
		return due - now
	}
	if state == .Loading {
		return -1
	}
	due := refreshed + BROWSE_REFRESH_MS
	if state == .Empty || now >= due {
		browse_refresh(app)
		return -1
	}
	return due - now
}

// Forgets everything fetched, releasing its images, and goes back to Following
// (after signing out).
browse_clear :: proc(app: ^App) {
	b := &app.browse
	browse_search_close(app)
	for l in ([]^Stream_List{&b.following, &b.top, &b.category}) {
		stream_list_clear(app, l)
	}
	for c in b.followed_categories {
		destroy_category(c)
	}
	clear(&b.followed_categories)
	for c in b.top_categories {
		destroy_category(c)
	}
	clear(&b.top_categories)
	delete(b.categories_next)
	b.categories_next = ""
	b.categories_state = .Empty
	clear(&b.cards)
	b.view = .Following
	b.categories_section = .Categories
	b.hovered = -1
	b.scroll = {}
}

@(private = "file")
stream_list_clear :: proc(app: ^App, l: ^Stream_List) {
	for s in l.streams {
		destroy_stream(s)
	}
	clear(&l.streams)
	for url in l.thumbnails {
		image_release(&app.assets.images, url)
		delete(url)
	}
	clear(&l.thumbnails)
	l.state = .Empty
}

// Fetches the view shown again (R).
browse_refresh :: proc(app: ^App) {
	b := &app.browse
	if !app.signed_in {
		return
	}
	switch b.view {
	case .Following, .Top, .Category:
		l := browse_list(b, b.view)
		if l.state == .Loading {
			return
		}
		l.state = .Loading
		jobs_add(
			&app.assets.jobs,
			run_streams_job,
			Streams_Job {
				client_id = strings.clone(app.client_id),
				auth = clone_auth(app.auth),
				view = b.view,
				game_id = strings.clone(b.category_id),
			},
		)
	case .Categories, .Followed_Categories:
		if b.categories_state == .Loading {
			return
		}
		b.categories_state = .Loading
		b.more_categories = false
		jobs_add(
			&app.assets.jobs,
			run_categories_job,
			Categories_Job{client_id = strings.clone(app.client_id), auth = clone_auth(app.auth)},
		)
	case .Search:
		search_start(app)
	}
}

// Fetches a stream list: the followed channels', the top streams, or a category's.
Streams_Job :: struct {
	client_id: string,
	// A copy; the job may refresh it.
	auth:      Auth,
	check:     Auth_Check,
	view:      Browse_View,
	// For the Category view.
	game_id:   string,
	ok:        bool,
	// Owned.
	streams:   [dynamic]Stream,
}

destroy_streams_job :: proc(p: ^Streams_Job) {
	for s in p.streams {
		destroy_stream(s)
	}
	delete(p.streams)
	delete(p.client_id)
	delete(p.game_id)
	destroy_auth(p.auth)
}

@(private = "file")
run_streams_job :: proc(job: ^Job) {
	p := &job.payload.(Streams_Job)
	fetch :: proc(p: ^Streams_Job) -> ([]Stream, Twitch_Error) {
		if p.view == .Following {
			return get_followed_streams(p.client_id, p.auth.access_token, p.auth.user_id)
		}
		return get_top_streams(p.client_id, p.auth.access_token, p.game_id)
	}
	p.check = .Valid
	streams, err := fetch(p)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		streams, err = fetch(p)
	}
	if err != .None {
		return
	}
	for s in streams {
		append(&p.streams, clone_stream(s))
	}
	p.ok = true
}

// On the main thread: replaces the list, releasing the old thumbnails. A category's
// streams arriving after another category was opened are dropped.
finish_streams_job :: proc(app: ^App, p: ^Streams_Job) {
	b := &app.browse
	if p.view == .Category && p.game_id != b.category_id {
		return
	}
	l := browse_list(b, p.view)
	l.last_refresh = app.assets.now_ms
	if !p.ok {
		l.state = .Failed if len(l.streams) == 0 else .Loaded
		return
	}
	stream_list_clear(app, l)
	l.refresh_count += 1
	for s in p.streams {
		append(&l.streams, s)
		url, _ := strings.replace_all(s.thumbnail_url, "{width}", fmt.tprint(THUMBNAIL_SIZE.x), context.temp_allocator)
		url, _ = strings.replace_all(url, "{height}", fmt.tprint(THUMBNAIL_SIZE.y), context.temp_allocator)
		// Twitch's CDN caches thumbnails; a new query string gets the current one.
		// The view's name in it keeps each list's copy apart, so releasing one
		// list's thumbnails can't take another's.
		append(&l.thumbnails, fmt.aprintf("%s?r=%v%d", url, p.view, l.refresh_count))
	}
	clear(&p.streams)
	l.state = .Loaded
}

// Fetches the followed categories and the first page of top ones, or (with
// `after`) the next page of top ones.
Categories_Job :: struct {
	client_id: string,
	auth:      Auth,
	check:     Auth_Check,
	after:     string,
	ok:        bool,
	// Owned.
	followed:  [dynamic]Category,
	top:       [dynamic]Category,
	next:      string,
}

destroy_categories_job :: proc(p: ^Categories_Job) {
	for c in p.followed {
		destroy_category(c)
	}
	delete(p.followed)
	for c in p.top {
		destroy_category(c)
	}
	delete(p.top)
	delete(p.after)
	delete(p.next)
	delete(p.client_id)
	destroy_auth(p.auth)
}

@(private = "file")
run_categories_job :: proc(job: ^Job) {
	p := &job.payload.(Categories_Job)
	p.check = .Valid
	followed, top, next, err := get_categories(p.client_id, p.auth.access_token, p.after)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		followed, top, next, err = get_categories(p.client_id, p.auth.access_token, p.after)
	}
	if err != .None {
		return
	}
	for c in followed {
		append(&p.followed, clone_category(c))
	}
	for c in top {
		append(&p.top, clone_category(c))
	}
	p.next = strings.clone(next)
	p.ok = true
}

// On the main thread. Box art never changes, so it stays loaded.
finish_categories_job :: proc(app: ^App, p: ^Categories_Job) {
	b := &app.browse
	if p.after != "" {
		finish_more_categories(app, p)
		return
	}
	b.categories_refreshed = app.assets.now_ms
	if !p.ok {
		has_any := len(b.followed_categories) + len(b.top_categories) > 0
		b.categories_state = .Loaded if has_any else .Failed
		return
	}
	for c in b.followed_categories {
		destroy_category(c)
	}
	for c in b.top_categories {
		destroy_category(c)
	}
	delete(b.followed_categories)
	delete(b.top_categories)
	b.followed_categories, p.followed = p.followed, {}
	b.top_categories, p.top = p.top, {}
	delete(b.categories_next)
	b.categories_next, p.next = p.next, ""
	b.categories_state = .Loaded
}

// Fetches the next page of top categories, once scrolling nears the end.
@(private = "file")
more_categories_start :: proc(app: ^App) {
	b := &app.browse
	if b.categories_next == "" || b.more_categories || b.categories_state != .Loaded {
		return
	}
	b.more_categories = true
	jobs_add(
		&app.assets.jobs,
		run_categories_job,
		Categories_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth),
			after = strings.clone(b.categories_next),
		},
	)
}

// Adds a page of top categories, unless the list was refreshed since it was asked
// for. Rankings shift between pages, so ones already listed are skipped, and the
// whole list is sorted again.
@(private = "file")
finish_more_categories :: proc(app: ^App, p: ^Categories_Job) {
	b := &app.browse
	if !b.more_categories || p.after != b.categories_next {
		return
	}
	b.more_categories = false
	if !p.ok {
		// Stop paging rather than retrying every frame; R starts over.
		delete(b.categories_next)
		b.categories_next = ""
		return
	}
	outer: for c in p.top {
		for have in b.top_categories {
			if have.id == c.id {
				continue outer
			}
		}
		append(&b.top_categories, clone_category(c))
	}
	sort_by_viewers(b.top_categories[:])
	delete(b.categories_next)
	b.categories_next, p.next = p.next, ""
}

// Searches channels for what's in the search box now.
@(private = "file")
search_start :: proc(app: ^App) {
	b := &app.browse
	query := strings.trim_space(input_text(&b.search))
	if query == "" {
		return
	}
	delete(b.search_query)
	b.search_query = strings.clone(query)
	b.search_state = .Loading
	jobs_add(
		&app.assets.jobs,
		run_search_job,
		Search_Job {
			client_id = strings.clone(app.client_id),
			auth = clone_auth(app.auth),
			kind = b.search_kind,
			query = strings.clone(query),
		},
	)
}

Search_Job :: struct {
	client_id:  string,
	auth:       Auth,
	check:      Auth_Check,
	kind:       Search_Kind,
	query:      string,
	ok:         bool,
	// Owned; as `kind` says.
	channels:   [dynamic]Channel,
	categories: [dynamic]Category,
}

destroy_search_job :: proc(p: ^Search_Job) {
	for c in p.channels {
		destroy_channel(c)
	}
	delete(p.channels)
	for c in p.categories {
		destroy_category(c)
	}
	delete(p.categories)
	delete(p.query)
	delete(p.client_id)
	destroy_auth(p.auth)
}

@(private = "file")
run_search_job :: proc(job: ^Job) {
	p := &job.payload.(Search_Job)
	search :: proc(p: ^Search_Job) -> Twitch_Error {
		switch p.kind {
		case .Channels:
			channels := search_channels(p.client_id, p.auth.access_token, p.query) or_return
			for c in channels {
				append(&p.channels, clone_channel(c))
			}
		case .Categories:
			categories := search_categories(p.client_id, p.auth.access_token, p.query) or_return
			for c in categories {
				append(&p.categories, clone_category(c))
			}
		}
		return .None
	}
	p.check = .Valid
	err := search(p)
	if err == .Unauthorized {
		p.check = refresh_auth(p.client_id, &p.auth)
		if p.check != .Refreshed {
			return
		}
		err = search(p)
	}
	p.ok = err == .None
}

// On the main thread: shows the results, unless the search has moved on since.
finish_search_job :: proc(app: ^App, p: ^Search_Job) {
	b := &app.browse
	if p.query != b.search_query || p.kind != b.search_kind {
		return
	}
	if !p.ok {
		b.search_state = .Failed
		return
	}
	results_clear(app)
	b.results, p.channels = p.channels, {}
	b.category_results, p.categories = p.categories, {}
	b.search_state = .Loaded
	b.selected = 0
}

// Forgets the search results, releasing their pictures: new ones come with every
// search, so keeping them would grow without end. Box art the Categories tab
// shows stays.
@(private = "file")
results_clear :: proc(app: ^App) {
	b := &app.browse
	for c in b.results {
		if c.thumbnail_url != "" {
			image_release(&app.assets.images, c.thumbnail_url)
		}
		destroy_channel(c)
	}
	delete(b.results)
	b.results = {}
	for c in b.category_results {
		if c.box_art_url != "" && !category_art_shown(b, c.box_art_url) {
			image_release(&app.assets.images, c.box_art_url)
		}
		destroy_category(c)
	}
	delete(b.category_results)
	b.category_results = {}
}

@(private = "file")
category_art_shown :: proc(b: ^Browse, url: string) -> bool {
	for list in ([][dynamic]Category{b.followed_categories, b.top_categories}) {
		for c in list {
			if c.box_art_url == url {
				return true
			}
		}
	}
	return false
}

// The channel the search's first row goes to by name: what's typed, if it's a
// valid login and no result is exactly that channel. Allocated with the temp
// allocator.
@(private = "file")
search_go_to :: proc(b: ^Browse) -> (login: string, ok: bool) {
	if b.search_kind != .Channels {
		return "", false
	}
	login = strings.to_lower(strings.trim_space(input_text(&b.search)), context.temp_allocator)
	if !valid_login(login) {
		return "", false
	}
	for c in b.results {
		if c.broadcaster_login == login {
			return "", false
		}
	}
	return login, true
}

@(private = "file")
search_row_count :: proc(b: ^Browse) -> int {
	if b.search_kind == .Categories {
		return len(b.category_results)
	}
	_, go_to := search_go_to(b)
	return len(b.results) + (1 if go_to else 0)
}

// Watches the channel on search row `i`, or opens the category.
@(private = "file")
search_open_row :: proc(app: ^App, i: int) {
	b := &app.browse
	if b.search_kind == .Categories {
		if i < 0 || i >= len(b.category_results) {
			return
		}
		c := clone_category(b.category_results[i])
		defer destroy_category(c)
		browse_search_close(app)
		browse_open_category(app, c)
		return
	}
	login, go_to := search_go_to(b)
	if !go_to {
		if i < 0 || i >= len(b.results) {
			return
		}
		login = b.results[i].broadcaster_login
	} else if i > 0 {
		if i - 1 >= len(b.results) {
			return
		}
		login = b.results[i - 1].broadcaster_login
	}
	browse_search_unfocus(app)
	watch_start(app, login)
}

// The channel's display name, with its login after it when they differ by more
// than case, as Twitch shows them: the login is always readable, even when the
// name is in a script no font here has.
channel_label :: proc(c: Channel) -> string {
	if strings.equal_fold(c.display_name, c.broadcaster_login) || c.display_name == "" {
		return c.display_name if c.display_name != "" else c.broadcaster_login
	}
	return fmt.tprintf("%s (%s)", c.display_name, c.broadcaster_login)
}

browse_search_focus :: proc(app: ^App) {
	b := &app.browse
	if b.search.focused || !app.signed_in {
		return
	}
	b.search.focused = true
	_ = sdl.StartTextInput(app.window)
}

browse_search_unfocus :: proc(app: ^App) {
	b := &app.browse
	if !b.search.focused {
		return
	}
	b.search.focused = false
	_ = sdl.StopTextInput(app.window)
}

// Empties the search box and goes back to the view before the search.
browse_search_close :: proc(app: ^App) {
	b := &app.browse
	browse_search_unfocus(app)
	input_clear(&b.search)
	delete(b.search_query)
	b.search_query = ""
	b.search_state = .Empty
	results_clear(app)
	if b.view == .Search {
		b.view = b.back_view
	}
	b.hovered = -1
}

// After the search box's text changed: shows the search, or leaves it when empty.
@(private = "file")
search_changed :: proc(app: ^App) {
	b := &app.browse
	b.search_edited = app.assets.now_ms
	b.selected = 0
	b.scroll[.Search] = 0
	if strings.trim_space(input_text(&b.search)) == "" {
		if b.view == .Search {
			b.view = b.back_view
		}
		return
	}
	if b.view != .Search {
		// From the view searched from, so before leaving it.
		b.search_kind = browse_search_kind(b)
		b.back_view = b.view
		b.view = .Search
	}
	b.hovered = -1
}

// What the search box searches from the view shown: categories from Categories (or
// a category), channels from anywhere else.
browse_search_kind :: proc(b: ^Browse) -> Search_Kind {
	#partial switch b.view {
	case .Categories, .Followed_Categories, .Category:
		return .Categories
	case .Search:
		return b.search_kind
	}
	return .Channels
}

browse_search_text :: proc(app: ^App, text: string) {
	b := &app.browse
	skip := b.skip_slash && text == "/"
	b.skip_slash = false
	if skip {
		return
	}
	input_insert(&b.search, text)
	search_changed(app)
}

// Keys while typing in the search box: Up and Down pick a result, Enter watches
// it, Esc closes the search.
browse_search_key :: proc(app: ^App, key: sdl.KeyboardEvent) {
	b := &app.browse
	b.skip_slash = false
	rows := search_row_count(b)
	switch key.key {
	case sdl.K_ESCAPE:
		browse_search_close(app)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		if b.view == .Search && rows > 0 {
			search_open_row(app, b.selected)
		}
	case sdl.K_UP, sdl.K_DOWN:
		// Categories are a grid: a step is a row of cards.
		step := max(b.result_columns, 1) if b.search_kind == .Categories else 1
		if key.key == sdl.K_UP {
			b.selected = max(b.selected - step, 0)
		} else {
			b.selected = clamp(b.selected + step, 0, max(rows - 1, 0))
		}
		b.reveal_selected = true
	case:
		before := input_text(&b.search)
		before = strings.clone(before, context.temp_allocator)
		if text_box_key(&b.search, key) && input_text(&b.search) != before {
			search_changed(app)
		}
	}
}

// Switches to a tab, leaving a search or a category.
browse_set_view :: proc(app: ^App, view: Browse_View) {
	b := &app.browse
	if b.view == .Search {
		browse_search_close(app)
	}
	b.view = view
	if view == .Categories {
		b.view = b.categories_section if b.categories_section == .Followed_Categories else .Categories
	}
	b.hovered = -1
}

// Shows a category's live streams, fetching them if it's not the one shown last.
@(private = "file")
browse_open_category :: proc(app: ^App, c: Category) {
	b := &app.browse
	if c.id != b.category_id {
		stream_list_clear(app, &b.category)
		delete(b.category_id)
		delete(b.category_name)
		b.category_id = strings.clone(c.id)
		b.category_name = strings.clone(c.name)
		b.scroll[.Category] = 0
	}
	b.category_viewers = c.viewers
	if b.view == .Categories || b.view == .Followed_Categories {
		b.categories_section = b.view
	}
	b.view = .Category
	b.hovered = -1
}

// Esc when not typing: leaves a category or a search. False if there was neither,
// so Esc can do what it does on the browse screen otherwise.
browse_back :: proc(app: ^App) -> bool {
	b := &app.browse
	#partial switch b.view {
	case .Category:
		category_back(app)
	case .Search:
		browse_search_close(app)
	case:
		return false
	}
	b.hovered = -1
	return true
}

browse_scroll :: proc(b: ^Browse, wheel_y, scale: f32) {
	b.scroll[b.view] = clamp(b.scroll[b.view] - wheel_y * BROWSE_SCROLL_STEP * scale, 0, b.max_scroll[b.view])
}

// The card (or search row) under (x, y), or -1.
browse_card_at :: proc(b: ^Browse, x, y: f32) -> int {
	if y < b.header_h {
		return -1
	}
	for rect, i in b.cards {
		if in_rect(rect, x, y) {
			return i
		}
	}
	return -1
}

// A left click on the browse screen. Returns true if it hit something.
browse_click :: proc(app: ^App, x, y: f32) -> bool {
	b := &app.browse
	if sign_in_click(app, x, y) {
		return true
	}
	for view in BROWSE_TABS {
		if in_rect(b.tabs[view], x, y) {
			browse_search_unfocus(app)
			browse_set_view(app, view)
			return true
		}
	}
	if b.search_rect.w > 0 && in_rect(b.search_rect, x, y) {
		browse_search_focus(app)
		return true
	}
	browse_search_unfocus(app)
	if b.back_button.w > 0 && in_rect(b.back_button, x, y) {
		category_back(app)
		return true
	}
	for button, i in b.section_buttons {
		if button.w > 0 && in_rect(button, x, y) {
			b.view = .Categories if i == 0 else .Followed_Categories
			b.categories_section = b.view
			b.hovered = -1
			return true
		}
	}
	i := browse_card_at(b, x, y)
	if i < 0 {
		return false
	}
	switch b.view {
	case .Following, .Top, .Category:
		l := browse_list(b, b.view)
		if i < len(l.streams) {
			watch_start(app, l.streams[i].user_login, info = &l.streams[i])
		}
	case .Categories:
		if i < len(b.top_categories) {
			browse_open_category(app, b.top_categories[i])
		}
	case .Followed_Categories:
		if i < len(b.followed_categories) {
			browse_open_category(app, b.followed_categories[i])
		}
	case .Search:
		search_open_row(app, i)
	}
	return true
}

// From a category back to the Categories tab's section it was opened from.
@(private = "file")
category_back :: proc(app: ^App) {
	b := &app.browse
	b.view = b.categories_section if b.categories_section == .Followed_Categories else .Categories
	b.hovered = -1
}

// Whether (x, y) is on something in the browse header that isn't for dragging the
// window: a tab or the search box.
on_browse_header_controls :: proc(app: ^App, x, y: f32) -> bool {
	b := &app.browse
	for view in BROWSE_TABS {
		if in_rect(b.tabs[view], x, y) {
			return true
		}
	}
	return b.search_rect.w > 0 && in_rect(b.search_rect, x, y)
}

draw_browse :: proc(app: ^App, screen: Rect) {
	r := &app.assets.renderer
	b := &app.browse
	draw_rect(r, screen, BROWSE_BACKGROUND)
	draw_browse_header(app, screen)

	clear(&b.cards)
	b.back_button = {}
	b.section_buttons = {}
	content := Rect{0, b.header_h, screen.w, screen.h - b.header_h}
	if !app.signed_in {
		draw_sign_in(app, content)
		return
	}
	switch b.view {
	case .Following:
		draw_stream_list(
			app,
			&b.following,
			content,
			"None of the channels you follow are live.",
			"Couldn't load the channels you follow. Press R to try again.",
		)
	case .Top:
		draw_stream_list(app, &b.top, content, "Nobody is live right now.", "Couldn't load the top streams. Press R to try again.")
	case .Category:
		draw_category(app, content)
	case .Categories, .Followed_Categories:
		draw_categories(app, content)
	case .Search:
		draw_search(app, content)
	}
}

// The tabs and search box at the left; who's signed in and the window buttons at
// the right.
@(private = "file")
draw_browse_header :: proc(app: ^App, screen: Rect) {
	r := &app.assets.renderer
	b := &app.browse
	scale := app.scale
	pad := BROWSE_PADDING * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	// Tall enough for the search box at any text size.
	box_h := line_height(r, .Regular, CHAT_FONT_SIZE * scale) + 2 * CHAT_PADDING * scale
	b.header_h = max(BROWSE_HEADER_HEIGHT * scale, box_h + 16 * scale)
	header_h := b.header_h
	text_y := (header_h - line_height(r, .Regular, text_size)) / 2

	// Window buttons at the far right, like a title bar's.
	controls_left := draw_window_controls(app, screen.w, 0)
	right := controls_left - pad
	app.sign_in.sign_out = {}
	if app.signed_in {
		// "R to refresh  ·  login  ·  Sign out", with "Sign out" clickable.
		label := "Sign out"
		lw := text_width(r, .Regular, text_size, label)
		app.sign_in.sign_out = {right - lw, text_y, lw, line_height(r, .Regular, text_size)}
		hovered := in_rect(app.sign_in.sign_out, app.mouse.x, app.mouse.y)
		draw_text(r, .Regular, text_size, app.sign_in.sign_out.x, text_y, label, BROWSE_TEXT if hovered else BROWSE_ACCENT)
		hint := fmt.tprintf("R to refresh  ·  %s  ·  ", app.auth.login)
		right = app.sign_in.sign_out.x - text_width(r, .Regular, text_size, hint)
		draw_text(r, .Regular, text_size, right, text_y, hint, BROWSE_DIM_TEXT)
	}

	b.tabs = {}
	b.search_rect = {}
	if !app.signed_in {
		title_size := BROWSE_TITLE_SIZE * scale
		draw_text(r, .Bold, title_size, pad, (header_h - line_height(r, .Bold, title_size)) / 2, "Following", BROWSE_TEXT)
		return
	}

	// Tabs, the one shown underlined; a category counts as Categories.
	tab_size := BROWSE_TAB_SIZE * scale
	tab_y := (header_h - line_height(r, .Bold, tab_size)) / 2
	x := pad
	for view in BROWSE_TABS {
		label := BROWSE_TAB_LABELS[view]
		lw := text_width(r, .Bold, tab_size, label)
		count := ""
		if view == .Following && (b.following.state == .Loaded || len(b.following.streams) > 0) {
			count = fmt.tprint(len(b.following.streams))
		}
		cw := text_width(r, .Regular, text_size, count) + 6 * scale if count != "" else 0
		b.tabs[view] = {x - 8 * scale, 0, lw + cw + 16 * scale, header_h}
		shown := b.view == view || (view == .Categories && (b.view == .Followed_Categories || b.view == .Category))
		hovered := in_rect(b.tabs[view], app.mouse.x, app.mouse.y)
		draw_text(r, .Bold, tab_size, x, tab_y, label, BROWSE_TEXT if shown || hovered else BROWSE_DIM_TEXT)
		if count != "" {
			draw_text(r, .Regular, text_size, x + lw + 6 * scale, text_y, count, BROWSE_DIM_TEXT)
		}
		if shown {
			draw_rect(r, {x, header_h - 3 * scale, lw, 3 * scale}, BROWSE_ACCENT)
		}
		x += lw + cw + 24 * scale
	}

	// The search box, in whatever room is left before the right side.
	w := min(BROWSE_SEARCH_WIDTH * scale * r.text_scale, right - pad - x)
	if w >= 120 * scale {
		b.search_rect = {x, (header_h - box_h) / 2, w, box_h}
		hint := "Search categories  ( / )" if browse_search_kind(b) == .Categories else "Search channels  ( / )"
		draw_text_box(app, &b.search, &b.search_box_scroll, b.search_rect, hint)
	}
}

// Live streams as cards, in as many columns as fit, stretched to fill the width.
@(private = "file")
draw_stream_list :: proc(app: ^App, l: ^Stream_List, content: Rect, empty_message, failed_message: string) {
	a := &app.assets
	r := &a.renderer
	b := &app.browse
	scale := app.scale
	pad := BROWSE_PADDING * scale
	gap := BROWSE_GAP * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	message := ""
	switch {
	case l.state == .Empty || (l.state == .Loading && len(l.streams) == 0):
		message = "Loading..."
	case l.state == .Failed:
		message = failed_message
	case len(l.streams) == 0:
		message = empty_message
	}
	if message != "" {
		draw_centered(r, .Regular, text_size, content, message, BROWSE_DIM_TEXT)
		return
	}

	min_w := BROWSE_CARD_WIDTH * scale
	columns := max(1, int((content.w - 2 * pad + gap) / (min_w + gap)))
	card_w := (content.w - 2 * pad - gap * f32(columns - 1)) / f32(columns)
	thumb_h := card_w * f32(THUMBNAIL_SIZE.y) / f32(THUMBNAIL_SIZE.x)
	card_title_size := BROWSE_CARD_TITLE_SIZE * scale
	lh_title := line_height(r, .Bold, card_title_size)
	lh_text := line_height(r, .Regular, text_size)
	text_pad := 8 * scale
	card_h := thumb_h + text_pad + lh_title + 2 * lh_text + text_pad
	rows := (len(l.streams) + columns - 1) / columns
	total_h := f32(rows) * card_h + f32(max(rows - 1, 0)) * gap + 2 * pad
	scroll := &b.scroll[b.view]
	b.max_scroll[b.view] = max(0, total_h - content.h)
	scroll^ = min(scroll^, b.max_scroll[b.view])

	clip_begin(r, content)
	for s, i in l.streams {
		col := i % columns
		row := i / columns
		card := Rect {
			content.x + pad + f32(col) * (card_w + gap),
			content.y + pad + f32(row) * (card_h + gap) - scroll^,
			card_w,
			card_h,
		}
		append(&b.cards, card)
		if card.y > content.y + content.h || card.y + card.h < content.y {
			continue
		}
		if i == b.hovered {
			draw_rect(r, card, BROWSE_CARD_HOVER)
		}

		thumb := Rect{card.x, card.y, card.w, thumb_h}
		// Thumbnails change every few minutes: not worth keeping on disk.
		image := image_get(&a.images, &a.jobs, l.thumbnails[i], 1, cache = false)
		if image.state == .Ready {
			texture, _ := image_frame(image, a.now_ms)
			draw_image(r, texture, thumb)
		} else {
			draw_rect(r, thumb, BROWSE_PLACEHOLDER)
		}

		// Viewer count over the thumbnail's bottom left, with a red live dot.
		viewers := format_viewers(s.viewer_count)
		vw := text_width(r, .Regular, text_size, viewers)
		dot := 8 * scale
		inset := 6 * scale
		badge := Rect{thumb.x + inset, thumb.y + thumb.h - inset - lh_text - 4 * scale, dot + 12 * scale + vw, lh_text + 4 * scale}
		draw_rect(r, badge, VIEWERS_BACKGROUND)
		draw_rect(r, {badge.x + 5 * scale, badge.y + (badge.h - dot) / 2, dot, dot}, LIVE_RED)
		draw_text(r, .Regular, text_size, badge.x + dot + 9 * scale, badge.y + 2 * scale, viewers, BROWSE_TEXT)

		tx := card.x + text_pad
		tw := card.w - 2 * text_pad
		ty := thumb.y + thumb.h + text_pad
		draw_text_line(a, .Bold, card_title_size, tx, ty, s.title, BROWSE_TEXT, tw)
		ty += lh_title
		draw_text(r, .Regular, text_size, tx, ty, fit_text(r, .Regular, text_size, s.user_name, tw), BROWSE_ACCENT)
		ty += lh_text
		draw_text(r, .Regular, text_size, tx, ty, fit_text(r, .Regular, text_size, s.game_name, tw), BROWSE_DIM_TEXT)
	}
	clip_end(r)
}

// One category: a heading with a back button, then its live streams.
@(private = "file")
draw_category :: proc(app: ^App, content: Rect) {
	r := &app.assets.renderer
	b := &app.browse
	scale := app.scale
	pad := BROWSE_PADDING * scale
	tab_size := BROWSE_TAB_SIZE * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	lh := line_height(r, .Bold, tab_size)
	heading_h := lh + pad
	y := content.y + pad / 2 + (heading_h - lh) / 2

	b.back_button = {content.x + pad / 2, content.y + pad / 2, 36 * scale * r.text_scale, heading_h}
	hovered := in_rect(b.back_button, app.mouse.x, app.mouse.y)
	if hovered {
		draw_rect(r, b.back_button, BROWSE_CARD_HOVER)
	}
	draw_centered(r, .Bold, tab_size * 1.6, b.back_button, "‹", BROWSE_TEXT)
	x := draw_text(r, .Bold, tab_size, b.back_button.x + b.back_button.w + 8 * scale, y, b.category_name, BROWSE_TEXT)
	if b.category_viewers > 0 {
		viewers := fmt.tprintf("%s viewers", format_viewers(b.category_viewers))
		ty := y + (lh - line_height(r, .Regular, text_size)) / 2
		draw_text(r, .Regular, text_size, x + 12 * scale, ty, viewers, BROWSE_DIM_TEXT)
	}

	rest := Rect{content.x, content.y + pad / 2 + heading_h, content.w, content.h - pad / 2 - heading_h}
	draw_stream_list(
		app,
		&b.category,
		rest,
		fmt.tprintf("Nobody is streaming %s right now.", b.category_name),
		"Couldn't load this category's streams. Press R to try again.",
	)
}

// The Categories tab: buttons for its two sections, then the one shown as box art
// cards. All categories fetches its next page once scrolling nears the end.
@(private = "file")
draw_categories :: proc(app: ^App, content: Rect) {
	r := &app.assets.renderer
	b := &app.browse
	scale := app.scale
	pad := BROWSE_PADDING * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	followed := b.view == .Followed_Categories

	// "All categories" and "Followed (10)", the one shown filled in.
	labels := [2]string{"All categories", fmt.tprintf("Followed (%d)", len(b.followed_categories))}
	lh := line_height(r, .Bold, text_size)
	button_pad := 12 * scale
	x := content.x + pad
	y := content.y + pad / 2
	for label, i in labels {
		w := text_width(r, .Bold, text_size, label) + 2 * button_pad
		button := Rect{x, y, w, lh + button_pad}
		b.section_buttons[i] = button
		shown := followed == (i == 1)
		hovered := in_rect(button, app.mouse.x, app.mouse.y)
		draw_rect(r, button, BROWSE_ACCENT if shown else (BROWSE_CARD_HOVER if hovered else BROWSE_PLACEHOLDER))
		draw_centered(r, .Bold, text_size, button, label, BROWSE_BACKGROUND if shown else BROWSE_TEXT)
		x += w + 8 * scale
	}
	top := y + lh + button_pad
	rest := Rect{content.x, top, content.w, content.y + content.h - top}

	categories := b.followed_categories[:] if followed else b.top_categories[:]
	if len(categories) == 0 {
		message := "Loading..."
		switch {
		case b.categories_state == .Failed:
			message = "Couldn't load categories. Press R to try again."
		case b.categories_state == .Loaded && followed:
			message = "You don't follow any categories."
		case b.categories_state == .Loaded:
			message = "No categories."
		}
		draw_centered(r, .Regular, text_size, rest, message, BROWSE_DIM_TEXT)
		return
	}
	if followed {
		draw_category_sections(app, rest, .Followed_Categories, {{"", categories}}, "", -1)
		return
	}
	footer := "Loading more..." if b.more_categories else ""
	draw_category_sections(app, rest, .Categories, {{"", categories}}, footer, -1)
	if b.max_scroll[.Categories] - b.scroll[.Categories] < rest.h {
		more_categories_start(app)
	}
}

Category_Section :: struct {
	title:      string,
	categories: []Category,
}

// Sections of category cards, each a heading and a grid, scrolled as `view`.
// `footer` shows after them; card `selected` (counting through every section) is
// marked. Returns the columns.
@(private = "file")
draw_category_sections :: proc(
	app: ^App,
	content: Rect,
	view: Browse_View,
	sections: []Category_Section,
	footer: string,
	selected: int,
) -> (
	columns: int,
) {
	a := &app.assets
	r := &a.renderer
	b := &app.browse
	scale := app.scale
	pad := BROWSE_PADDING * scale
	gap := BROWSE_GAP * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	min_w := BROWSE_CATEGORY_WIDTH * scale * r.text_scale
	columns = max(1, int((content.w - 2 * pad + gap) / (min_w + gap)))
	card_w := (content.w - 2 * pad - gap * f32(columns - 1)) / f32(columns)
	art_h := card_w * f32(BOX_ART_SIZE.y) / f32(BOX_ART_SIZE.x)
	card_title_size := BROWSE_CARD_TITLE_SIZE * scale
	lh_title := line_height(r, .Bold, card_title_size)
	lh_text := line_height(r, .Regular, text_size)
	text_pad := 8 * scale
	card_h := art_h + text_pad + lh_title + lh_text + text_pad
	heading_size := BROWSE_TAB_SIZE * scale
	// Untitled sections have no heading.
	heading_h := line_height(r, .Bold, heading_size) + text_pad if len(sections) > 0 && sections[0].title != "" else 0

	section_h :: proc(n, columns: int, heading_h, card_h, gap: f32) -> f32 {
		rows := (n + columns - 1) / columns
		return heading_h + f32(rows) * card_h + f32(max(rows - 1, 0)) * gap
	}
	total_h := pad
	for s in sections {
		total_h += section_h(len(s.categories), columns, heading_h, card_h, gap) + pad
	}
	if footer != "" {
		total_h += lh_text + pad
	}
	scroll := &b.scroll[view]
	b.max_scroll[view] = max(0, total_h - content.h)
	if b.reveal_selected && selected >= 0 {
		// Only the search reveals, and it has one section.
		b.reveal_selected = false
		top := pad + heading_h + f32(selected / columns) * (card_h + gap)
		if top - scroll^ < 0 {
			scroll^ = top - pad - heading_h
		} else if top + card_h - scroll^ > content.h {
			scroll^ = top + card_h + pad - content.h
		}
	}
	scroll^ = clamp(scroll^, 0, b.max_scroll[view])

	clip_begin(r, content)
	y := content.y + pad - scroll^
	index := 0
	for s in sections {
		if s.title != "" {
			draw_text(r, .Bold, heading_size, content.x + pad, y, s.title, BROWSE_TEXT)
		}
		top := y + heading_h
		for c, i in s.categories {
			col := i % columns
			row := i / columns
			card := Rect{content.x + pad + f32(col) * (card_w + gap), top + f32(row) * (card_h + gap), card_w, card_h}
			append(&b.cards, card)
			defer index += 1
			if card.y > content.y + content.h || card.y + card.h < content.y {
				continue
			}
			if index == b.hovered || index == selected {
				draw_rect(r, card, BROWSE_CARD_HOVER)
			}
			art := Rect{card.x, card.y, card.w, art_h}
			image := image_get(&a.images, &a.jobs, c.box_art_url, 1) if c.box_art_url != "" else nil
			if image != nil && image.state == .Ready {
				texture, _ := image_frame(image, a.now_ms)
				draw_image(r, texture, art)
			} else {
				draw_rect(r, art, BROWSE_PLACEHOLDER)
			}
			if index == selected {
				draw_rect(r, {card.x, card.y + card.h - 3 * scale, card.w, 3 * scale}, BROWSE_ACCENT)
			}
			tx := card.x + text_pad
			tw := card.w - 2 * text_pad
			ty := art.y + art.h + text_pad
			draw_text(r, .Bold, card_title_size, tx, ty, fit_text(r, .Bold, card_title_size, c.name, tw), BROWSE_TEXT)
			viewers := fmt.tprintf("%s viewers", format_viewers(c.viewers))
			draw_text(r, .Regular, text_size, tx, ty + lh_title, fit_text(r, .Regular, text_size, viewers, tw), BROWSE_DIM_TEXT)
		}
		y += section_h(len(s.categories), columns, heading_h, card_h, gap) + pad
	}
	if footer != "" {
		draw_text(r, .Regular, text_size, content.x + pad, y, footer, BROWSE_DIM_TEXT)
	}
	clip_end(r)
	return
}

// Channels matching the search: profile picture, name, and whether they're live
// (with the game and title) or not. The first row may go to the typed name.
@(private = "file")
draw_search :: proc(app: ^App, content: Rect) {
	a := &app.assets
	r := &a.renderer
	b := &app.browse
	scale := app.scale
	pad := BROWSE_PADDING * scale
	text_size := BROWSE_CARD_TEXT_SIZE * scale
	name_size := BROWSE_CARD_TITLE_SIZE * scale
	lh_name := line_height(r, .Bold, name_size)
	lh_text := line_height(r, .Regular, text_size)
	row_pad := 8 * scale
	row_h := lh_name + lh_text + 2 * row_pad
	row_gap := 4 * scale
	avatar := row_h - 2 * row_pad
	go_to, has_go_to := search_go_to(b)
	rows := search_row_count(b)
	b.selected = clamp(b.selected, 0, max(rows - 1, 0))
	found := len(b.results) if b.search_kind == .Channels else len(b.category_results)

	status := ""
	switch {
	case b.search_state == .Failed:
		status = "Search failed. Press R to try again."
	case b.search_state == .Loaded && found == 0 && b.search_query == strings.trim_space(input_text(&b.search)):
		status = "No channels found." if b.search_kind == .Channels else "No categories found."
	case found == 0:
		status = "Searching..."
	}
	if b.search_kind == .Categories {
		sections := []Category_Section{{"Categories", b.category_results[:]}}
		if found == 0 {
			sections = {}
		}
		b.result_columns = draw_category_sections(app, content, .Search, sections, status, b.selected if found > 0 else -1)
		return
	}
	status_h := lh_text + pad if status != "" else 0
	total_h := 2 * pad + f32(rows) * (row_h + row_gap) + status_h
	scroll := &b.scroll[.Search]
	b.max_scroll[.Search] = max(0, total_h - content.h)
	if b.reveal_selected {
		b.reveal_selected = false
		top := pad + f32(b.selected) * (row_h + row_gap)
		if top - scroll^ < 0 {
			scroll^ = top - pad
		} else if top + row_h - scroll^ > content.h {
			scroll^ = top + row_h + pad - content.h
		}
	}
	scroll^ = clamp(scroll^, 0, b.max_scroll[.Search])

	list_w := min(content.w - 2 * pad, BROWSE_RESULTS_WIDTH * scale * r.text_scale)
	clip_begin(r, content)
	y := content.y + pad - scroll^
	for i in 0 ..< rows {
		row := Rect{content.x + pad, y, list_w, row_h}
		append(&b.cards, row)
		y += row_h + row_gap
		if row.y > content.y + content.h || row.y + row.h < content.y {
			continue
		}
		if i == b.selected || i == b.hovered {
			draw_rect(r, row, BROWSE_CARD_HOVER)
		}
		if i == b.selected {
			draw_rect(r, {row.x, row.y, 3 * scale, row.h}, BROWSE_ACCENT)
		}
		pic := Rect{row.x + row_pad, row.y + row_pad, avatar, avatar}
		tx := pic.x + pic.w + 12 * scale
		tw := row.x + row.w - row_pad - tx
		ty := row.y + row_pad

		if has_go_to && i == 0 {
			draw_rect(r, pic, BROWSE_PLACEHOLDER)
			draw_centered(r, .Bold, name_size * 1.4, pic, "›", BROWSE_ACCENT)
			draw_text(r, .Bold, name_size, tx, ty, fit_text(r, .Bold, name_size, fmt.tprintf("Go to %s", go_to), tw), BROWSE_TEXT)
			draw_text(r, .Regular, text_size, tx, ty + lh_name, "Open the channel by its name", BROWSE_DIM_TEXT)
			continue
		}
		c := b.results[i - 1 if has_go_to else i]
		image := image_get(&a.images, &a.jobs, c.thumbnail_url, 1) if c.thumbnail_url != "" else nil
		if image != nil && image.state == .Ready {
			texture, _ := image_frame(image, a.now_ms)
			draw_image(r, texture, pic)
		} else {
			draw_rect(r, pic, BROWSE_PLACEHOLDER)
		}
		x := draw_text(r, .Bold, name_size, tx, ty, fit_text(r, .Bold, name_size, channel_label(c), tw), BROWSE_ACCENT)
		detail := "Offline"
		if c.is_live {
			// A red dot and "LIVE" after the name.
			dot := 8 * scale
			x += 10 * scale
			draw_rect(r, {x, ty + (lh_name - dot) / 2, dot, dot}, LIVE_RED)
			draw_text(r, .Bold, text_size, x + dot + 5 * scale, ty + (lh_name - lh_text) / 2, "LIVE", LIVE_RED)
			detail = c.title if c.game_name == "" else fmt.tprintf("%s  ·  %s", c.game_name, c.title)
		}
		draw_text_line(a, .Regular, text_size, tx, ty + lh_name, detail, BROWSE_DIM_TEXT if !c.is_live else BROWSE_TEXT, tw)
	}
	if status != "" {
		draw_text(r, .Regular, text_size, content.x + pad, y + pad / 2, status, BROWSE_DIM_TEXT)
	}
	clip_end(r)
}

draw_centered :: proc(r: ^Renderer, font: Font, size: f32, area: Rect, text: string, color: Color) {
	w := text_width(r, font, size, text)
	h := line_height(r, font, size)
	draw_text(r, font, size, area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, text, color)
}

// "999", "1.2K", "12.3K", "1.5M": Twitch's style.
format_viewers :: proc(n: int) -> string {
	switch {
	case n < 1000:
		return fmt.tprint(n)
	case n < 1_000_000:
		return trim_point_zero(fmt.tprintf("%.1fK", f64(n) / 1000))
	case:
		return trim_point_zero(fmt.tprintf("%.1fM", f64(n) / 1_000_000))
	}
}

@(private = "file")
trim_point_zero :: proc(s: string) -> string {
	if len(s) > 3 && s[len(s) - 3:len(s) - 1] == ".0" {
		return strings.concatenate({s[:len(s) - 3], s[len(s) - 1:]}, context.temp_allocator)
	}
	return s
}

// The text, cut short with "…" if it's wider than max_w. Allocated with the temp
// allocator when cut.
fit_text :: proc(r: ^Renderer, font: Font, size: f32, text: string, max_w: f32) -> string {
	if text_width(r, font, size, text) <= max_w {
		return text
	}
	ellipsis :: "…"
	room := max_w - text_width(r, font, size, ellipsis)
	end := 0
	for i := 0; i < len(text); {
		_, n := utf8.decode_rune_in_string(text[i:])
		if text_width(r, font, size, text[:i + n]) > room {
			break
		}
		i += n
		end = i
	}
	return strings.concatenate({strings.trim_right_space(text[:end]), ellipsis}, context.temp_allocator)
}
