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
# VERSION=X.Y.Z を渡すと、アプリの版にする（リリースのワークフローが、タグから渡す）。未指定なら、Info.plist のまま。署名の前に書き換える。
if [ -n "${VERSION:-}" ]; then
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build.sh: VERSION は X.Y.Z の形で指定してください: $VERSION" >&2; exit 1; }
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
# アイコン（scripts/make-icon.sh で生成してコミットしたもの）。MenuBarIcon.png は、メニューバーの項目が実行時に読む。
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png "$APP/Contents/Resources/"
# SIGN_IDENTITY 未指定なら ad-hoc 署名（手元用）。Developer ID を指定すると Hardened Runtime つきで署名する。
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/ShortNote"
