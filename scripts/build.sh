#!/bin/bash
# Universal (arm64 + x86_64) ShortNote.app を build/ に作る。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64

APP=build/ShortNote.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN/ShortNote" "$APP/Contents/MacOS/ShortNote"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SIGN_IDENTITY 未指定なら ad-hoc 署名（手元用）。Developer ID を指定すると Hardened Runtime つきで署名する。
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/ShortNote"
