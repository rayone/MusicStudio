#!/usr/bin/env bash
#
# MusicStudio launcher: builds the app if the bundle is missing or stale
# (any source/resource newer than the built binary), then opens it.
# Double-click in Finder or run from a terminal.

set -e

cd "$(dirname "$0")"

APP_NAME="MusicStudio.app"
BIN="$APP_NAME/Contents/MacOS/MusicStudio"

needs_build=0
if [ ! -x "$BIN" ]; then
    needs_build=1
else
    # Rebuild if any tracked source or resource is newer than the built binary.
    while IFS= read -r f; do
        if [ "$f" -nt "$BIN" ]; then
            needs_build=1
            break
        fi
    done < <(find Sources Resources build.command -type f 2>/dev/null)
fi

if [ "$needs_build" -eq 1 ]; then
    echo "==> Building MusicStudio (bundle missing or stale)..."
    bash build.command
fi

open "$APP_NAME"
