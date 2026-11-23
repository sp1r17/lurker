# Roadmap to 1.0

Lurker 0.11.0 covers almost everything people do on Twitch as viewers: browsing,
live streams, past broadcasts and clips, chat with third-party emotes, and basic
moderation. Lurker is for Twitch only. Every feature planned for 1.0 lands
before it, since 1.0 starts with a feature freeze; after that, 1.0 is about being
something people can install from the usual places, set up without reading the
README, and rely on.

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

## 0.10: Robustness and macOS (released)

- GraphQL failures handled per feature: what didn't load says why, telling an
  API change apart from Twitch being unreachable
- Copy log and Open log folder in Settings, and issue templates asking for the
  version, platform and log
- A memory leak fixed: the seek bar's preview images
- macOS on Apple silicon, built and tested in CI with a disk image in each
  release. No live notifications there: they need an app signed with an Apple
  Developer ID, which Lurker won't have

## 0.11: Distribution (released)

- A Flatpak repository on GitHub Pages: installing once is enough, and
  `flatpak update` picks up new releases. The release's bundle installs from it
  too
- Tested on X11 and Sway: Lurker now quits when the compositor or X server goes
  away, and window dragging on Wayland survives the mouse reconnecting
- x86-64 only on Linux and Windows for 1.0

## 0.12: Missing viewer features

Left over from 0.11:

- Sign the Windows installer and executable, through SignPath Foundation's free
  signing for open-source projects
- Test window moving, resizing and fullscreen on GNOME (it starts and plays)
- More testing on Windows, and taking the "new and hasn't had much testing"
  note out of the README once it's earned

Channel points and drops. Watching in Lurker earns none today: Twitch counts
watch time from reports its own player sends, and streamlink sends none.

- Report each minute a live stream plays, as Twitch's player does, so watching
  earns channel points and drop progress. Paused or buffering minutes don't
  count, and if Twitch changes how this works, only this stops (done for
  channel points; drop progress not checked yet)
- The channel points balance, and claiming the bonus automatically
- Claiming finished drops automatically

Chat:

- Pinned chat messages, and polls and predictions shown above the chat
- Shared Chat: show which channel each message came from
- Chat over the video in fullscreen, with its position, size and background
  adjustable
- More chat options: hiding badges, highlighting bits and your own messages,
  lines between messages, the viewer or chatter count above the chat, and still
  emotes instead of animated ones
- Whispers

Playback and notifications:

- Lower the quality when the stream keeps buffering
- Muted parts of past broadcasts shown on the seek bar
- A video enhancement setting with three presets: Off; Balanced, with
  debanding and a sharper scaler at almost no cost; and Upscale, which adds a
  neural upscaler (FSRCNNX or RAVU) when the window is bigger than the video
  (done, with FSRCNNX)
- Audio normalization, evening out loud and quiet streamers and sudden alerts
  (done)
- Choosing the audio output device, and an audio delay for Bluetooth
  headphones
- Screenshots of the video, without Lurker's UI, at the stream's resolution
- Stepping frame by frame through past broadcasts and clips (`,` and `.`)
- Notify when a followed channel changes its title or category
- Keyboard shortcut list in the app (`?`)

## 0.13: Bigger features

- Multistream: two to four streams at once, side by side or one large with the
  others small, choosing which one is heard
- A mini player while browsing: the stream being watched keeps playing in a
  small window or a live thumbnail
- A preview of a stream when hovering its card
- A buffered mode, the opposite of low latency: rewinding a live stream by a
  few seconds, saving the last minute to a file, speeding up slightly to catch
  up when the stream falls behind, and smooth motion on high refresh rate
  screens
- Themes

## 1.0: Release candidate

- Feature freeze; one or two release candidates with bug fixes only
- Accessibility pass: keyboard navigation everywhere, readable contrast, and
  text size covering the whole UI
- Bring the README and the Flatpak's metainfo up to date, with new screenshots
- Release 1.0

## After 1.0

- Try submitting to Flathub
- Intel Macs and older macOS versions
- ARM Linux and Windows
