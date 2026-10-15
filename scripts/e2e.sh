#!/bin/bash
# native E2E を、実行中の ShortNote に影響しない形で実行する。
# build/ShortNote.app の bundle ID だけを変えた検証用コピー（build/ShortNoteE2E.app）を作って、それに対して実行する。
# 本番の bundle ID のままだと、起動した候補が、常駐中のあなたのインスタンスへ転送され、保存したキャンバスのサイズも混ざる。
# 実行中は、マウスとキーボードに触れないこと（物理のポインタとキーを使う）。
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d build/ShortNote.app ] || ./scripts/build.sh

COPY=build/ShortNoteE2E.app
rm -rf "$COPY"
cp -R build/ShortNote.app "$COPY"
plutil -replace CFBundleIdentifier -string dev.takemo101.shortnote.e2e "$COPY/Contents/Info.plist"
codesign --force --sign - "$COPY" >/dev/null 2>&1

exec /usr/bin/swift scripts/native-e2e.swift "$PWD/$COPY/Contents/MacOS/ShortNote" --artifacts "$PWD/build/native-e2e"
