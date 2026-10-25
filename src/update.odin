package app

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

// Lurker checks GitHub for a newer release when it starts and every
// UPDATE_CHECK_MS, and offers it at the top of the browse screen. On Windows it
// updates itself: the installer is downloaded, checked against the release's
// SHA256SUMS and run silently, and reopens Lurker. Elsewhere the release page opens.
LATEST_RELEASE_URL :: "https://api.github.com/repos/sp1r17/lurker/releases/latest"
UPDATE_CHECK_MS :: 6 * 3600 * 1000
UPDATE_INSTALLS_ITSELF :: ODIN_OS == .Windows

Update_State :: enum {
	Idle,
	Checking,
	// A newer version is out (Updater.version).
	Available,
	Downloading,
	// The download or its check failed: the release page is offered instead.
	Failed,
}

Updater :: struct {
	state:      Update_State,
	// When it last checked (Assets.now_ms); 0 for never.
	checked_at: int,
	// The newer release: its version ("0.4.1") and page, and the Windows installer
	// and checksums to download. Owned.
	version:    string,
	page:       string,
	installer:  string,
	sums:       string,
	// Closed (×) for this run.
	dismissed:  bool,
	// From the last draw (zero size when hidden): the bar and its links.
	bar:        Rect,
	update_link: Rect,
	skip_link:  Rect,
	close_link: Rect,
}

updater_destroy :: proc(u: ^Updater) {
	delete(u.version)
	delete(u.page)
	delete(u.installer)
	delete(u.sums)
}

// "0.4.1" or "v0.4.1" as numbers. False for anything else.
parse_version :: proc(s: string) -> (v: [3]int, ok: bool) {
	rest := strings.trim_prefix(s, "v")
	i := 0
	for part in strings.split_iterator(&rest, ".") {
		if i == 3 {
			return {}, false
		}
		n, parsed := strconv.parse_int(part, 10)
		if !parsed || n < 0 {
			return {}, false
		}
		v[i] = n
		i += 1
	}
	return v, i == 3
}

// Whether version `a` is newer than `b`.
version_newer :: proc(a, b: string) -> bool {
	va, ok_a := parse_version(a)
	vb, ok_b := parse_version(b)
	if !ok_a || !ok_b {
		return false
	}
	for i in 0 ..< 3 {
		if va[i] != vb[i] {
			return va[i] > vb[i]
		}
	}
	return false
}

// Checks for a newer version when one is due. Returns ms until the next check,
// for the main loop's wait, or -1.
update_tick :: proc(app: ^App) -> (wait_ms: int) {
	u := &app.update
	if app.layout.update_checks_off || u.state == .Checking || u.state == .Downloading {
		return -1
	}
	due := u.checked_at + UPDATE_CHECK_MS
	now := app.assets.now_ms
	if u.checked_at == 0 || now >= due {
		u.state = .Checking if u.state == .Idle else u.state
		u.checked_at = max(now, 1)
		jobs_add(&app.assets.jobs, run_update_check_job, Update_Check_Job{})
		return -1
	}
	return due - now
}

Update_Check_Job :: struct {
	ok:        bool,
	// Owned.
	version:   string,
	page:      string,
	installer: string,
	sums:      string,
}

destroy_update_check_job :: proc(p: ^Update_Check_Job) {
	delete(p.version)
	delete(p.page)
	delete(p.installer)
	delete(p.sums)
}

@(private = "file")
run_update_check_job :: proc(job: ^Job) {
	p := &job.payload.(Update_Check_Job)
	res, ok := http_request(LATEST_RELEASE_URL, {"Accept: application/vnd.github+json"}, allocator = context.temp_allocator)
	if !ok {
		return
	}
	if res.status != 200 {
		log.warnf("checking for updates: HTTP %d", res.status)
		return
	}
	p.ok = parse_latest_release(res.body, p)
}

// The version, page and Windows downloads of GitHub's latest release, into `p`.
parse_latest_release :: proc(body: []byte, p: ^Update_Check_Job) -> bool {
	Asset :: struct {
		name:                 string,
		browser_download_url: string,
	}
	Release :: struct {
		tag_name: string,
		html_url: string,
		assets:   []Asset,
	}
	r: Release
	if json.unmarshal(body, &r, allocator = context.temp_allocator) != nil {
		return false
	}
	if _, ok := parse_version(r.tag_name); !ok || !strings.has_prefix(r.html_url, "https://github.com/") {
		return false
	}
	p.version = strings.clone(strings.trim_prefix(r.tag_name, "v"))
	p.page = strings.clone(r.html_url)
	setup := fmt.tprintf("lurker-%s-x86_64-setup.exe", p.version)
	for a in r.assets {
		switch a.name {
		case setup:
			p.installer = strings.clone(a.browser_download_url)
		case "SHA256SUMS":
			p.sums = strings.clone(a.browser_download_url)
		}
	}
	return true
}

finish_update_check_job :: proc(app: ^App, p: ^Update_Check_Job) {
	u := &app.update
	if u.state == .Checking {
		u.state = .Idle
	}
	if !p.ok || u.state != .Idle || app.layout.update_checks_off {
		return
	}
	if !version_newer(p.version, APP_VERSION) || p.version == app.layout.skipped_version {
		return
	}
	updater_destroy(u)
	u.version, p.version = p.version, ""
	u.page, p.page = p.page, ""
	u.installer, p.installer = p.installer, ""
	u.sums, p.sums = p.sums, ""
	u.state = .Available
	log.infof("Lurker %s is available", u.version)
}

// Whether the update bar shows at the top of the browse screen.
update_bar_shown :: proc(app: ^App) -> bool {
	u := &app.update
	return (u.state == .Available || u.state == .Downloading || u.state == .Failed) && !u.dismissed
}

// The Update button: on Windows, downloads the installer to run it; elsewhere, or
// without the release's installer and checksums, opens the release page.
update_start :: proc(app: ^App) {
	u := &app.update
	if !UPDATE_INSTALLS_ITSELF || u.state == .Failed || u.installer == "" || u.sums == "" {
		open_url(u.page)
		return
	}
	if u.state != .Available {
		return
	}
	u.state = .Downloading
	jobs_add(
		&app.assets.jobs,
		run_update_download_job,
		Update_Download_Job{version = strings.clone(u.version), installer = strings.clone(u.installer), sums = strings.clone(u.sums)},
	)
}

Update_Download_Job :: struct {
	version:   string,
	installer: string,
	sums:      string,
	// Where the checked installer was saved. Owned.
	path:      string,
	ok:        bool,
}

destroy_update_download_job :: proc(p: ^Update_Download_Job) {
	delete(p.version)
	delete(p.installer)
	delete(p.sums)
	delete(p.path)
}

@(private = "file")
run_update_download_job :: proc(job: ^Job) {
	p := &job.payload.(Update_Download_Job)
	name := fmt.tprintf("lurker-%s-x86_64-setup.exe", p.version)
	sums, sums_ok := http_request(p.sums, allocator = context.temp_allocator)
	if !sums_ok || sums.status != 200 {
		log.warn("update: can't download SHA256SUMS")
		return
	}
	want, listed := checksum_for(string(sums.body), name)
	if !listed {
		log.warnf("update: SHA256SUMS doesn't list %s", name)
		return
	}
	setup, setup_ok := http_request(p.installer, allocator = context.temp_allocator)
	if !setup_ok || setup.status != 200 {
		log.warn("update: can't download the installer")
		return
	}
	if got := sha256_hex(setup.body); got != want {
		log.errorf("update: the installer's checksum is %s, not %s", got, want)
		return
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	if dir_err != nil {
		return
	}
	path, join_err := filepath.join({dir, name}, context.temp_allocator)
	if join_err != nil {
		return
	}
	if err := os.write_entire_file(path, setup.body); err != nil {
		log.errorf("update: can't save %s: %v", path, err)
		return
	}
	p.path = strings.clone(path)
	p.ok = true
}

// The SHA-256 that a sha256sum listing gives `name`, lowercase hex.
checksum_for :: proc(listing, name: string) -> (sum: string, ok: bool) {
	rest := listing
	for line in strings.split_lines_iterator(&rest) {
		hash, _, file := strings.partition(strings.trim_space(line), " ")
		file = strings.trim_left(strings.trim_space(file), "*")
		if file == name && len(hash) == 64 {
			return strings.to_lower(hash, context.temp_allocator), true
		}
	}
	return "", false
}

// Allocated with the temp allocator.
sha256_hex :: proc(data: []byte) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	hash: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, hash[:])
	sb := strings.builder_make(context.temp_allocator)
	for b in hash {
		fmt.sbprintf(&sb, "%02x", b)
	}
	return strings.to_string(sb)
}

// Runs the checked installer silently and quits, so it can replace Lurker's
// files; the installer opens Lurker again when it's done.
finish_update_download_job :: proc(app: ^App, p: ^Update_Download_Job) {
	u := &app.update
	if u.state != .Downloading {
		return
	}
	if !p.ok {
		u.state = .Failed
		return
	}
	if _, err := os.process_start({command = {p.path, "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART"}}); err != nil {
		log.errorf("update: can't run the installer: %v", err)
		u.state = .Failed
		return
	}
	log.infof("updating to %s", u.version)
	e: sdl.Event
	e.type = .QUIT
	_ = sdl.PushEvent(&e)
}

// Turns update checks on or off, and remembers it.
update_checks_toggle :: proc(app: ^App) {
	app.layout.update_checks_off = !app.layout.update_checks_off
	if app.layout.update_checks_off && app.update.state != .Downloading {
		app.update.state = .Idle
	}
	app.update.checked_at = 0
	layout_save(&app.layout)
}

// "Lurker 0.4.1 is out.  Update  ·  Skip this version  ×" under the header.
// Returns its height.
draw_update_bar :: proc(app: ^App, y, width: f32) -> f32 {
	u := &app.update
	u.bar, u.update_link, u.skip_link, u.close_link = {}, {}, {}, {}
	if !update_bar_shown(app) {
		return 0
	}
	r := &app.assets.renderer
	scale := app.scale
	pad := BROWSE_PADDING * scale
	size := BROWSE_CARD_TEXT_SIZE * scale
	lh := line_height(r, .Regular, size)
	u.bar = {0, y, width, lh + 16 * scale}
	draw_rect(r, u.bar, CHAT_HEADER)
	draw_rect(r, {0, y + u.bar.h - scale, width, scale}, CHAT_DIVIDER)
	ty := y + (u.bar.h - lh) / 2

	message, action: string
	switch u.state {
	case .Downloading:
		message = fmt.tprintf("Downloading Lurker %s...", u.version)
	case .Failed:
		message, action = fmt.tprintf("Couldn't update to Lurker %s.", u.version), "Download it"
	case .Idle, .Checking, .Available:
		message = fmt.tprintf("Lurker %s is out.", u.version)
		action = "Update" if UPDATE_INSTALLS_ITSELF && u.installer != "" && u.sums != "" else "Download"
	}
	x := pad
	draw_text(r, .Regular, size, x, ty, message, BROWSE_TEXT)
	x += text_width(r, .Regular, size, message) + pad
	link :: proc(app: ^App, label: string, x, y, size: f32) -> Rect {
		r := &app.assets.renderer
		rect := Rect{x, y, text_width(r, .Bold, size, label), line_height(r, .Regular, size)}
		hovered := in_rect(rect, app.mouse.x, app.mouse.y)
		draw_text(r, .Bold, size, x, y, label, BROWSE_TEXT if hovered else BROWSE_ACCENT)
		return rect
	}
	if action != "" {
		u.update_link = link(app, action, x, ty, size)
		x += u.update_link.w + pad
	}
	if u.state == .Available {
		u.skip_link = link(app, "Skip this version", x, ty, size)
	}
	if u.state != .Downloading {
		u.close_link = {width - pad - u.bar.h, y, u.bar.h, u.bar.h}
		hovered := in_rect(u.close_link, app.mouse.x, app.mouse.y)
		draw_centered(r, .Bold, 18 * scale, u.close_link, "×", BROWSE_TEXT if hovered else BROWSE_DIM_TEXT)
	}
	return u.bar.h
}

// A click on the update bar. Returns true if it hit it.
update_bar_click :: proc(app: ^App, x, y: f32) -> bool {
	u := &app.update
	if u.bar.w == 0 || !in_rect(u.bar, x, y) {
		return false
	}
	switch {
	case in_rect(u.update_link, x, y):
		update_start(app)
	case in_rect(u.skip_link, x, y):
		delete(app.layout.skipped_version)
		app.layout.skipped_version = strings.clone(u.version)
		layout_save(&app.layout)
		u.state = .Idle
	case in_rect(u.close_link, x, y):
		u.dismissed = true
	}
	return true
}
