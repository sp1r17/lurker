# Roadmap to 1.0

Lurker 0.9.0 covers almost everything people do on Twitch as viewers: browsing,
live streams, past broadcasts and clips, chat with third-party emotes, and basic
moderation. Lurker is for Twitch only. 1.0 is less about new features than about being something people can
install from the usual places, set up without reading the README, and rely on.

## What 1.0 means

- Easy to install and keep updated: the Flatpak updates with `flatpak update`,
  and the Windows installer runs without SmartScreen warnings
- Every setting reachable from one settings screen
- No known crashes, freezes or data loss; the last releases ran for weeks
  without one
- Settings and sign-in files that newer versions keep reading, so updates never
  reset anything
- When Twitch changes something (most likely the GraphQL API), the affected
  feature fails on its own with a clear message instead of breaking the app

## 0.8: Settings (released)

- A settings screen collecting what was spread across the top bar and the
  quality menu
- A version field in the saved files, with migration from older versions

## 0.9: Viewer features (released)

- The stream's exact qualities, and an optional highest quality
- Stream stats, with ping to Twitch and latency to the broadcaster
- Chat delayed to match the stream, and a buffer for low latency
- Sorting, uptime on live cards, a History tab, a chosen start page, and clips
  by period
- Following categories, and per-channel live notifications, from the
  right-click menu
- Chat timestamps, streamer and moderator highlights, hidden bots, and
  alternating backgrounds
- New screenshots

## 0.10: Robustness and macOS

Left over from 0.8 and 0.9:

- Handle GraphQL failures per feature: hide or disable what didn't load, and
  say why, instead of showing empty lists (done)
- A "Copy log" or "Open log folder" action, for bug reports (done)
- Issue templates asking for the version, platform and log (done)

New:

- macOS on Apple silicon: build and test it in CI, and publish the disk image
  with each release (both done); get notifications working, which needs a
  signed app bundle

## 0.11: Distribution

- Host a Flatpak repository for Lurker (on GitHub Pages, say) with a
  `.flatpakrepo` file, so installing once is enough and `flatpak update` picks
  up new releases, instead of downloading each release's bundle
- Sign the Windows installer and executable
- Test and fix X11 (the Flatpak allows it as a fallback, but it's untested), and
  more than KDE on Wayland (GNOME, Sway/Hyprland)
- Decide on aarch64: drop `odin-x86-only.patch` and build for ARM, or state it
  isn't supported
- More testing on Windows, and taking the "new and hasn't had much testing"
  note out of the README once it's earned

## 0.12: Missing viewer features

Pick what's worth doing before 1.0; everything else can come after.

- Pinned chat messages, and polls and predictions shown above the chat
- Channel points balance and claiming the bonus
- Whispers
- Picture-in-picture or a mini player while browsing
- Keyboard shortcut list in the app (`?`)

## 1.0: Release candidate

- Feature freeze; one or two release candidates with bug fixes only
- Accessibility pass: keyboard navigation everywhere, readable contrast, and
  text size covering the whole UI
- Bring the README and the Flatpak's metainfo up to date, with new screenshots
- Release 1.0

## After 1.0

- Try submitting to Flathub
- Intel Macs and older macOS versions
- Themes
- Multistream: two to four streams at once, side by side or one large with the
  others small, choosing which one is heard
- A preview of a stream when hovering its card
- The stream being watched kept playing as a live thumbnail while browsing
