# Roadmap to 1.0

Lurker 0.7.0 covers almost everything people do on Twitch as viewers: browsing,
live streams, past broadcasts and clips, chat with third-party emotes, and basic
moderation. 1.0 is less about new features than about being something people can
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

## 0.8: Settings and robustness

- A settings screen collecting what's now spread across the top bar and the
  quality menu: notifications, update checks, language, raid following, low
  latency, text size, blocked channels and categories, highlights and ignored
  users, and sign-out
- A version field in `config.json` and the layout file, with migration from
  older versions
- Handle GraphQL failures per feature: hide or disable what didn't load, and
  say why, instead of showing empty lists
- A "Copy log" or "Open log folder" action, for bug reports
- Issue templates asking for the version, platform and log

## 0.9: Distribution

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

## 0.10: Missing viewer features

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
- macOS
- Other platforms' chats (YouTube, Kick) beside Twitch
- Themes
