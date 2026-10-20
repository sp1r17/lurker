#!/usr/bin/env bash
set -e

OUT_DIR="build"
OUT_NAME="twitch-app"
MODE="${1:-debug}"

mkdir -p "$OUT_DIR"

case "$MODE" in
  release)
    echo "Building release..."
    odin build src \
      -out:"$OUT_DIR/$OUT_NAME" \
      -o:speed \
      -no-bounds-check \
      -disable-assert
    ;;
  debug | run)
    echo "Building debug..."
    odin build src \
      -out:"$OUT_DIR/$OUT_NAME" \
      -debug \
      -vet \
      -strict-style
    ;;
  test)
    odin test src -debug -vet -strict-style -out:"$OUT_DIR/tests"
    exit 0
    ;;
  *)
    echo "Usage: $0 [debug|release|run <channel>|test]"
    exit 1
    ;;
esac

echo "Build complete: $OUT_DIR/$OUT_NAME"

if [ "$MODE" == "run" ]; then
  "./$OUT_DIR/$OUT_NAME" "${@:2}"
fi
