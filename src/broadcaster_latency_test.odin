package app

import "core:encoding/endian"
import "core:testing"

@(test)
latency_playlist_gives_the_newest_segment :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	playlist := `#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MAP:URI="https://x/init.mp4"
#EXT-X-PROGRAM-DATE-TIME:2026-11-19T19:16:35.780Z
#EXTINF:2.000,live
https://x/seg-1.mp4
#EXT-X-PROGRAM-DATE-TIME:2026-11-19T19:16:37.780Z
#EXTINF:2.000,live
https://x/seg-2.mp4
#EXT-X-TWITCH-PREFETCH:https://x/seg-3.mp4
`
	init_url, segment_url, received, ok := parse_latency_playlist(playlist)
	testing.expect(t, ok)
	testing.expect_value(t, init_url, "https://x/init.mp4")
	testing.expect_value(t, segment_url, "https://x/seg-2.mp4")
	// 2026-11-19T19:16:37.780Z
	testing.expect(t, abs(received - 1795115797.780) < 0.001)
	// MPEG-TS segments have no init segment.
	_, _, _, ok = parse_latency_playlist("#EXTM3U\n#EXT-X-PROGRAM-DATE-TIME:2026-11-19T19:16:37.780Z\n#EXTINF:2.000,live\nhttps://x/seg.ts\n")
	testing.expect(t, !ok)
}

@(private = "file")
box :: proc(type: string, parts: ..[]byte) -> []byte {
	size := 8
	for p in parts {
		size += len(p)
	}
	out := make([dynamic]byte, 8, size, context.temp_allocator)
	endian.put_u32(out[:4], .Big, u32(size))
	copy(out[4:8], type)
	for p in parts {
		append(&out, ..p)
	}
	return out[:]
}

@(private = "file")
be32 :: proc(v: u32) -> []byte {
	b := make([]byte, 4, context.temp_allocator)
	endian.put_u32(b, .Big, v)
	return b
}

@(private = "file")
be64 :: proc(v: u64) -> []byte {
	b := make([]byte, 8, context.temp_allocator)
	endian.put_u64(b, .Big, v)
	return b
}

@(test)
fragment_start_reads_tfdt_in_its_tracks_timescale :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	zero4 := be32(0)
	// As Twitch's: audio (track 1, 48 kHz), then video (track 2, microseconds).
	trak :: proc(id, scale: u32, zero4: []byte) -> []byte {
		// Version 0: flags, two times, then the ID; the same before the timescale.
		tkhd := box("tkhd", zero4, zero4, zero4, be32(id))
		mdhd := box("mdhd", zero4, zero4, zero4, be32(scale))
		return box("trak", tkhd, box("mdia", mdhd))
	}
	init := box("moov", trak(1, 48000, zero4), trak(2, 1_000_000, zero4))
	// Version 1 tfdt: 64 bits.
	tfdt := box("tfdt", be32(0x0100_0000), be64(383521808))
	moof := box("moof", box("traf", box("tfhd", zero4, be32(1)), tfdt))
	emsg := box("emsg", make([]byte, 400, context.temp_allocator))
	segment := make([dynamic]byte, context.temp_allocator)
	append(&segment, ..emsg)
	append(&segment, ..moof)
	start, ok := fragment_start(segment[:], init)
	testing.expect(t, ok)
	testing.expect(t, abs(start - 383521808.0 / 48000) < 1e-6)
	// A track the init segment doesn't have.
	other := box("moof", box("traf", box("tfhd", zero4, be32(9)), tfdt))
	_, ok = fragment_start(other, init)
	testing.expect(t, !ok)
	_, ok = fragment_start({}, init)
	testing.expect(t, !ok)
}
