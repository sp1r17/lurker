package app

import "core:crypto/ed25519"
import "core:encoding/hex"
import "core:fmt"
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
		{"name":"lurker-0.5.0-x86_64.flatpak","browser_download_url":"https://github.com/sp1r17/lurker/releases/download/v0.5.0/lurker-0.5.0-x86_64.flatpak"},
		{"name":"lurker-0.5.0-x86_64-setup.exe","browser_download_url":"https://github.com/sp1r17/lurker/releases/download/v0.5.0/lurker-0.5.0-x86_64-setup.exe"},
		{"name":"SHA256SUMS","browser_download_url":"https://github.com/sp1r17/lurker/releases/download/v0.5.0/SHA256SUMS"},
		{"name":"SHA256SUMS.sig","browser_download_url":"https://github.com/sp1r17/lurker/releases/download/v0.5.0/SHA256SUMS.sig"}]}`
	p: Update_Check_Job
	defer destroy_update_check_job(&p)
	testing.expect(t, parse_latest_release(transmute([]byte)string(body), &p))
	testing.expect_value(t, p.version, "0.5.0")
	testing.expect_value(t, p.installer, "https://github.com/sp1r17/lurker/releases/download/v0.5.0/lurker-0.5.0-x86_64-setup.exe")
	testing.expect_value(t, p.sums, "https://github.com/sp1r17/lurker/releases/download/v0.5.0/SHA256SUMS")
	testing.expect_value(t, p.signature, "https://github.com/sp1r17/lurker/releases/download/v0.5.0/SHA256SUMS.sig")

	bad: Update_Check_Job
	defer destroy_update_check_job(&bad)
	testing.expect(t, !parse_latest_release(transmute([]byte)string(`{"tag_name":"nightly","html_url":"https://github.com/x"}`), &bad))
}

@(test)
latest_release_stays_on_lurkers_releases :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for page in ([]string{
		"https://github.com/someone/else/releases/tag/v0.5.0",
		"https://github.com/sp1r17/lurker/releases/tag/../../../evil",
		"https://github.com.evil.example/sp1r17/lurker/releases/tag/v0.5.0",
		"http://github.com/sp1r17/lurker/releases/tag/v0.5.0",
	}) {
		p: Update_Check_Job
		body := fmt.tprintf(`{{"tag_name":"v0.5.0","html_url":"%s"}}`, page)
		testing.expectf(t, !parse_latest_release(transmute([]byte)body, &p), "%s isn't Lurker's release page", page)
		destroy_update_check_job(&p)
	}

	// A download from elsewhere is left out, so the page opens instead of it.
	body := `{"tag_name":"v0.5.0","html_url":"https://github.com/sp1r17/lurker/releases/tag/v0.5.0","assets":[
		{"name":"lurker-0.5.0-x86_64-setup.exe","browser_download_url":"https://evil.example/setup.exe"},
		{"name":"SHA256SUMS","browser_download_url":"https://github.com/sp1r17/lurker/releases/download/v0.5.0/../../../../x/SHA256SUMS"},
		{"name":"SHA256SUMS.sig","browser_download_url":"https://github.com/sp1r17/lurker/releases/download/v0.5.0/SHA256SUMS.sig"}]}`
	p: Update_Check_Job
	defer destroy_update_check_job(&p)
	testing.expect(t, parse_latest_release(transmute([]byte)string(body), &p))
	testing.expect_value(t, p.installer, "")
	testing.expect_value(t, p.sums, "")
	testing.expect_value(t, p.signature, "https://github.com/sp1r17/lurker/releases/download/v0.5.0/SHA256SUMS.sig")
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

// A signature made by `openssl pkeyutl -sign -rawin`, as the release job makes
// SHA256SUMS.sig, with a throwaway key.
@(test)
signatures_are_checked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	key :: "cf42a4d1464e175d92a28e6c2a026548c0d3aed8dd3aa754aced4e83267edb8c"
	sums := "abc123  lurker-0.13.0-x86_64-setup.exe\n"
	signature, _ := hex.decode(transmute([]byte)string("2d7b372cbc524e3ac025f75cf6b830fe193880533e13c02e3059f97921a99c01ba2cc1de0ef7cad0b64e986a0e9846c4acdb4ea977c5cf7ade1cf6b1f9b8010d"), context.temp_allocator)
	testing.expect(t, signed_by(key, transmute([]byte)sums, signature))

	tampered := "abc124  lurker-0.13.0-x86_64-setup.exe\n"
	testing.expect(t, !signed_by(key, transmute([]byte)tampered, signature))
	other_key :: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
	testing.expect(t, !signed_by(other_key, transmute([]byte)sums, signature))
	testing.expect(t, !signed_by(key, transmute([]byte)sums, signature[:63]))
	testing.expect(t, !signed_by("not hex", transmute([]byte)sums, signature))
}

// The key built in is a real Ed25519 public key, so updates can be checked at all.
@(test)
update_public_key_is_valid :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bytes, ok := hex.decode(transmute([]byte)string(UPDATE_PUBLIC_KEY), context.temp_allocator)
	testing.expect(t, ok && len(bytes) == ed25519.PUBLIC_KEY_SIZE)
	key: ed25519.Public_Key
	testing.expect(t, ok && ed25519.public_key_set_bytes(&key, bytes))
}
