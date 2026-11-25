# Roadmap to 1.0

Lurker 0.12.0 covers almost everything people do on Twitch as viewers: browsing,
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

## 0.12: Missing viewer features (released)

- Watching earns channel points; the balance shows, and bonuses and finished
  drops are claimed automatically
- Chat: pinned messages and predictions above it, Shared Chat shown by each
  channel's picture, whispers, chat over the video in any window (moved and
  resized with the mouse), more chat options, and 10,000 messages kept
- Playback: a lower quality when the stream keeps buffering, muted parts on the
  seek bar, video enhancement, audio normalization, sound output and Bluetooth
  delay settings, screenshots, and stepping frame by frame
- Notifications for title and category changes, and the keyboard shortcut list
  (`?`)

## 0.13: Bigger features

Left over from 0.12:

- Sign the Windows installer and executable, through SignPath Foundation's free
  signing for open-source projects
- Test window moving, resizing and fullscreen on GNOME (it starts and plays)
- More testing on Windows, and taking the "new and hasn't had much testing"
  note out of the README once it's earned
- See working live what couldn't be tested yet: claiming a bonus and a finished
  drop, drop progress from watching, a real Shared Chat session, and sending a
  whisper

New:

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

Chat, catching up with Chatterino:

- Selecting and copying chat text, and Copy message on a message's right-click
  menu (done)
- A sound and a flashing taskbar entry on mentions and highlight phrases, each
  optional
- Messages sent with a channel point reward marked with the reward's name, and
  announcements in their color
- Polls above the chat, as predictions are
- Highlighting everyone's messages from chosen people or with a chosen badge
  (VIPs, subscribers...), each in a color of its own; highlight phrases as
  whole words, with case, or as regular expressions
- Ignoring phrases as well as people, or replacing them with other words
- Nicknames: your own name for someone, shown in place of theirs
- Search filters in Ctrl+F: `from:`, `has:link`, `is:mention` and the like
- Moderation from the chat: timeout, ban and delete buttons on each message,
  AutoMod's held messages to allow or deny, and `/vip`, `/mod`, `/raid`,
  `/shoutout`, `/announce`, `/poll`, `/marker`, `/slow` and `/color`; for
  everyone, a note when AutoMod holds your own message
- A Mentions view: every mention of you, from all the chats open
- Link previews on hovering a link, off by default: the page's title,
  description and picture, fetched by Lurker itself (Twitch clips and videos
  through Twitch's API)
- Streamer mode: hides whispers, link previews and your account's details
  while you stream
- More than one account, switching between them
- Custom commands, and changing keyboard shortcuts
- Saving chats to log files

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
