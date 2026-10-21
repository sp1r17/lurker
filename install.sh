#!/usr/bin/env bash
# Builds the release and installs it for the current user (~/.local by default),
# with an app-menu entry and icon. Settings and sign-in stay in
# ~/.config/twitch-app and are never touched, even by --uninstall.
set -e

usage() {
  echo "Usage: $0 [--prefix <dir>] [--no-build] [--uninstall]"
  echo "  --prefix <dir>  install under <dir> (default: ~/.local; /usr/local needs sudo)"
  echo "  --no-build      install the existing build/twitch-app instead of building"
  echo "  --uninstall     remove an installed copy"
  echo "DESTDIR is honoured, for packaging."
}

PREFIX="$HOME/.local"
BUILD=1
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ -n "$2" ] || { usage; exit 1; }
      PREFIX="$2"
      shift
      ;;
    --no-build) BUILD=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

cd "$(dirname "$0")"
ROOT="${DESTDIR}${PREFIX}"
BIN="$ROOT/bin/twitch-app"
DESKTOP="$ROOT/share/applications/twitch-app.desktop"
ICON="$ROOT/share/icons/hicolor/scalable/apps/twitch-app.svg"
ICON_PNG="$ROOT/share/icons/hicolor/256x256/apps/twitch-app.png"

refresh_caches() {
  # Only for a live install; packagers' post-install scripts do this.
  [ -z "$DESTDIR" ] || return 0
  if command -v update-desktop-database > /dev/null; then
    update-desktop-database -q "$ROOT/share/applications" || true
  fi
  # A stale cache hides icons added after it was made.
  local icons="$ROOT/share/icons/hicolor"
  if command -v gtk-update-icon-cache > /dev/null && { [ -f "$icons/icon-theme.cache" ] || [ -f "$icons/index.theme" ]; }; then
    gtk-update-icon-cache -q -f -t "$icons" || true
  fi
  if command -v kbuildsycoca6 > /dev/null; then
    kbuildsycoca6 > /dev/null 2>&1 || true
  fi
  # Plasma keeps the icons it found at startup; this makes it look again.
  if command -v dbus-send > /dev/null; then
    dbus-send --session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0 2> /dev/null || true
  fi
}

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$BIN" "$DESKTOP" "$ICON" "$ICON_PNG"
  refresh_caches
  echo "Removed twitch-app from $ROOT."
  echo "Settings and sign-in are still in ~/.config/twitch-app; delete it to remove them."
  exit 0
fi

# The libraries it links against, and streamlink, which plays the video.
missing=()
for lib in libmpv.so.2 libSDL3.so.0 libSDL3_image.so.0 libcurl.so.4 libwayland-client.so.0; do
  ldconfig -p 2> /dev/null | grep -q "$lib" || missing+=("$lib")
done
command -v streamlink > /dev/null || missing+=("streamlink")
if [ "$BUILD" = 1 ]; then
  command -v odin > /dev/null || missing+=("odin (to build)")
fi
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing: ${missing[*]}"
  echo "  Fedora: sudo dnf install mpv-libs SDL3 SDL3_image libcurl libwayland-client streamlink"
  echo "  Arch:   sudo pacman -S mpv sdl3 sdl3_image curl wayland streamlink"
  echo "  Debian/Ubuntu: sudo apt install libmpv2 libsdl3-0 libsdl3-image0 libcurl4 libwayland-client0 streamlink"
  exit 1
fi

if [ "$BUILD" = 1 ]; then
  ./build.sh release
fi
[ -x build/twitch-app ] || { echo "No build/twitch-app; run without --no-build."; exit 1; }

install -Dm755 build/twitch-app "$BIN"
install -Dm644 assets/install/twitch-app.svg "$ICON"
install -Dm644 assets/install/twitch-app.png "$ICON_PNG"
# The menu entry runs the installed binary by its full path, so it works even
# when $PREFIX/bin isn't on the PATH.
mkdir -p "$(dirname "$DESKTOP")"
sed "s|^Exec=twitch-app|Exec=$PREFIX/bin/twitch-app|" assets/install/twitch-app.desktop > "$DESKTOP"
chmod 644 "$DESKTOP"
refresh_caches

echo "Installed twitch-app to $ROOT."
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "Note: $PREFIX/bin isn't on your PATH; the app menu entry still works." ;;
esac
echo "Sign in from the app, or with: twitch-app --login"
