#!/usr/bin/env bash
# Builds Lurker.app for Apple silicon Macs, with mpv and SDL (from Homebrew) and
# streamlink (with its own Python) inside, and a disk image holding it. The app is
# signed ad hoc, not with a Developer ID, and works on the macOS version it's
# built on and later, as Homebrew's libraries do.
#
#   brew install sdl3 sdl3_image mpv dylibbundler
#   packaging/macos/build.sh [version]
set -euo pipefail

VERSION="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/macos"
DEPS="$OUT/deps"
APP="$OUT/Lurker.app"
BREW="$(brew --prefix)"
MINIMUM_OS="$(sw_vers -productVersion | cut -d. -f1).0"

# A relocatable Python from python-build-standalone, and the streamlink the other
# builds use.
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.14.10%2B20261110-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_SHA="42031ed5f0d38777335252c8c77d64708c8010dd67c128246bdec25000672666"
STREAMLINK_VERSION="8.6.2"

# Downloads $1 to $3 unless it's there already, and checks it against $2.
fetch() {
  if [ ! -f "$3" ] || ! echo "$2  $3" | shasum -a 256 -c - > /dev/null 2>&1; then
    echo "Downloading $1"
    curl -sSfL -o "$3" "$1"
  fi
  echo "$2  $3" | shasum -a 256 -c - > /dev/null || { echo "$3 doesn't match its checksum"; exit 1; }
}

mkdir -p "$DEPS"
fetch "$PYTHON_URL" "$PYTHON_SHA" "$DEPS/python.tar.gz"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@MINIMUM_OS@/$MINIMUM_OS/g" \
  "$ROOT/packaging/macos/Info.plist" > "$APP/Contents/Info.plist"
cp "$ROOT/assets/install/lurker.icns" "$APP/Contents/Resources/lurker.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

# Lurker itself.
odin build "$ROOT/src" -out:"$APP/Contents/MacOS/lurker" -o:speed -no-bounds-check -disable-assert \
  -minimum-os-version:"$MINIMUM_OS" "-extra-linker-flags:-L$BREW/lib"

# The libraries it loads (SDL3, SDL3_image, libmpv and theirs), copied from
# Homebrew into Frameworks and pointed at there. It would ask where a library it
# can't find is; no answer makes it fail instead.
dylibbundler -cd -of -b -x "$APP/Contents/MacOS/lurker" -d "$APP/Contents/Frameworks" \
  -p @executable_path/../Frameworks/ -s "$BREW/lib" < /dev/null > /dev/null

# streamlink, installed into its own Python in Resources/streamlink.
STREAMLINK="$APP/Contents/Resources/streamlink"
mkdir -p "$STREAMLINK"
tar xzf "$DEPS/python.tar.gz" -C "$STREAMLINK"
"$STREAMLINK/python/bin/python3" -m pip install --quiet --disable-pip-version-check --no-cache-dir \
  --only-binary=:all: "streamlink==$STREAMLINK_VERSION"
rm -rf "$STREAMLINK/python/lib/python3."*/test "$STREAMLINK/python/lib/python3."*/idlelib
cp "$ROOT/packaging/macos/streamlink" "$STREAMLINK/streamlink"

# Ad hoc signatures: the libraries first, then the app around them.
codesign --force --sign - "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# Nothing may still load from Homebrew, which the user's Mac needn't have.
if otool -L "$APP/Contents/MacOS/lurker" "$APP/Contents/Frameworks/"*.dylib | grep -F "$BREW/"; then
  echo "Lurker.app still loads the libraries above from Homebrew"
  exit 1
fi
"$STREAMLINK/streamlink" --version

# The disk image: the app beside a link to Applications, to drag it onto.
DMG="$OUT/lurker-$VERSION-arm64.dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# hdiutil now and then fails with "Resource busy" on CI machines.
for attempt in 1 2 3; do
  if hdiutil create -volname Lurker -srcfolder "$STAGE" -format UDZO -quiet "$DMG"; then
    break
  fi
  [ "$attempt" -lt 3 ] || exit 1
  sleep 5
done
rm -rf "$STAGE"
echo "Built $DMG"
