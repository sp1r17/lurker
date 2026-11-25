#!/usr/bin/env bash
# Builds Lurker.app for Apple silicon Macs, with mpv, SDL and curl (from
# Homebrew) and streamlink (with its own Python) inside, and a disk image holding
# it. The app is signed ad hoc, not with a Developer ID, and works on the macOS
# version it's built on and later, as Homebrew's libraries do.
#
#   brew install sdl3 sdl3_image mpv curl dylibbundler
#   packaging/macos/build.sh [version]
set -euo pipefail

VERSION="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/macos"
DEPS="$OUT/deps"
APP="$OUT/Lurker.app"
BREW="$(brew --prefix)"
BREW_CURL="$(brew --prefix curl)"
MINIMUM_OS="$(sw_vers -productVersion | cut -d. -f1).0"

# A relocatable Python from python-build-standalone. streamlink, the version the
# other builds use, and what it needs are pinned in streamlink-requirements.txt.
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.14.10%2B20261110-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_SHA="42031ed5f0d38777335252c8c77d64708c8010dd67c128246bdec25000672666"

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

# Lurker itself, with Homebrew's curl: macOS's own lacks WebSockets, which chat
# needs. With bounds checks, as chat and emotes come from anyone.
odin build "$ROOT/src" -out:"$APP/Contents/MacOS/lurker" -o:speed -disable-assert \
  -minimum-os-version:"$MINIMUM_OS" "-extra-linker-flags:-L$BREW_CURL/lib -L$BREW/lib"

# The libraries it loads (SDL3, SDL3_image, libmpv, libcurl and theirs), copied from
# Homebrew into Frameworks and pointed at there. It would ask where a library it
# can't find is; no answer makes it fail instead.
dylibbundler -cd -of -b -x "$APP/Contents/MacOS/lurker" -d "$APP/Contents/Frameworks" \
  -p @executable_path/../Frameworks/ -s "$BREW/lib" -s "$BREW_CURL/lib" < /dev/null > /dev/null

# dylibbundler can give a library the same search path twice (libmpv, reached
# from Lurker and from its dependencies), and macOS won't load a library like
# that. Each repeated one is removed and added back once.
rpaths() {
  otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }'
}
for file in "$APP/Contents/MacOS/lurker" "$APP/Contents/Frameworks/"*.dylib; do
  rpaths "$file" | sort | uniq -d | while read -r rpath; do
    while [ "$(rpaths "$file" | grep -cxF "$rpath" || true)" -gt 0 ]; do
      install_name_tool -delete_rpath "$rpath" "$file"
    done
    install_name_tool -add_rpath "$rpath" "$file"
  done
done

# streamlink, installed into its own Python in Resources/streamlink.
STREAMLINK="$APP/Contents/Resources/streamlink"
mkdir -p "$STREAMLINK"
tar xzf "$DEPS/python.tar.gz" -C "$STREAMLINK"
"$STREAMLINK/python/bin/python3" -m pip install --quiet --disable-pip-version-check --no-cache-dir \
  --only-binary=:all: --require-hashes -r "$ROOT/packaging/macos/streamlink-requirements.txt"
rm -rf "$STREAMLINK/python/lib/python3."*/test "$STREAMLINK/python/lib/python3."*/idlelib
cp "$ROOT/packaging/macos/streamlink" "$STREAMLINK/streamlink"

# Homebrew's libraries aren't pinned (its bottles are checked against its signed
# index, but the versions are whatever it has that day), so the app records the
# ones it was built with, for checking a build later.
FORMULAE=(sdl3 sdl3_image mpv curl)
# shellcheck disable=SC2046
brew list --versions "${FORMULAE[@]}" $(brew deps --union "${FORMULAE[@]}") | sort -u \
  > "$APP/Contents/Resources/homebrew-versions.txt"
echo "Homebrew libraries:"
cat "$APP/Contents/Resources/homebrew-versions.txt"

# Ad hoc signatures: the libraries first, then the app around them.
codesign --force --sign - "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# Nothing may still load from Homebrew, which the user's Mac needn't have.
if otool -L "$APP/Contents/MacOS/lurker" "$APP/Contents/Frameworks/"*.dylib | grep -F "$BREW/"; then
  echo "Lurker.app still loads the libraries above from Homebrew"
  exit 1
fi
if otool -L "$APP/Contents/MacOS/lurker" | grep -F /usr/lib/libcurl; then
  echo "Lurker.app loads macOS's curl, which can't connect to chat"
  exit 1
fi
curl_version="$("$BREW_CURL/bin/curl" --version)"
if ! grep -qw wss <<< "$curl_version"; then
  echo "Homebrew's curl lacks WebSockets, which chat needs"
  exit 1
fi
"$STREAMLINK/streamlink" --version
# macOS loads every library as Lurker starts, so starting it shows they all load:
# it prints its usage and exits 2 for an argument that isn't a channel.
set +e
"$APP/Contents/MacOS/lurker" --check-libraries 2> /dev/null
status=$?
set -e
if [ "$status" -ne 2 ]; then
  echo "Lurker.app doesn't start (exit $status): a library didn't load"
  DYLD_PRINT_LIBRARIES=1 "$APP/Contents/MacOS/lurker" --check-libraries 2>&1 | tail -20 || true
  exit 1
fi

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
