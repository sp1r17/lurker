package app

import "core:strings"
import "core:testing"

@(test)
versions_compare :: proc(t: ^testing.T) {
	testing.expect(t, version_newer("0.4.1", "0.4.0"))
	testing.expect(t, version_newer("v0.10.0", "0.9.9"))
	testing.expect(t, version_newer("1.0.0", "0.99.99"))
	testing.expect(t, !version_newer("0.4.0", "0.4.0"))
	testing.expect(t, !version_newer("0.3.9", "0.4.0"))
	testing.expect(t, !version_newer("0.5", "0.4.0"))
	testing.expect(t, !version_newer("0.5.0-beta", "0.4.0"))
	_, ok := parse_version(APP_VERSION)
	testing.expect(t, ok)
}

// The metainfo's newest release is the version the app reports.
@(test)
version_matches_metainfo :: proc(t: ^testing.T) {
	metainfo :: #load("../packaging/flatpak/io.github.sp1r17.Lurker.metainfo.xml", string)
	_, _, rest := strings.partition(metainfo, `<release version="`)
	version, _, _ := strings.partition(rest, `"`)
	testing.expect_value(t, version, APP_VERSION)
}

@(test)
latest_release_parses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"tag_name":"v0.5.0","html_url":"https://github.com/sp1r17/lurker/releases/tag/v0.5.0","assets":[
		{"name":"lurker-0.5.0-x86_64.flatpak","browser_download_url":"https://github.com/x/flatpak"},
		{"name":"lurker-0.5.0-x86_64-setup.exe","browser_download_url":"https://github.com/x/setup"},
		{"name":"SHA256SUMS","browser_download_url":"https://github.com/x/sums"}]}`
	p: Update_Check_Job
	defer destroy_update_check_job(&p)
	testing.expect(t, parse_latest_release(transmute([]byte)string(body), &p))
	testing.expect_value(t, p.version, "0.5.0")
	testing.expect_value(t, p.installer, "https://github.com/x/setup")
	testing.expect_value(t, p.sums, "https://github.com/x/sums")

	bad: Update_Check_Job
	defer destroy_update_check_job(&bad)
	testing.expect(t, !parse_latest_release(transmute([]byte)string(`{"tag_name":"nightly","html_url":"https://github.com/x"}`), &bad))
}

@(test)
checksums_are_found :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	listing := "ABC0000000000000000000000000000000000000000000000000000000000001  lurker-0.5.0-x86_64.flatpak\n" +
		"def0000000000000000000000000000000000000000000000000000000000002 *lurker-0.5.0-x86_64-setup.exe\n"
	sum, ok := checksum_for(listing, "lurker-0.5.0-x86_64-setup.exe")
	testing.expect(t, ok)
	testing.expect_value(t, sum, "def0000000000000000000000000000000000000000000000000000000000002")
	_, missing := checksum_for(listing, "other.exe")
	testing.expect(t, !missing)
	testing.expect_value(t, sha256_hex(transmute([]byte)string("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}
