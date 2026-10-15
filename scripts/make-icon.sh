#!/bin/bash
# アイコンを生成して、Resources/ に置く（AppIcon.icns、MenuBarIcon.png）。生成物はコミットする。
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

/usr/bin/swift scripts/make-icon.swift "$work"
iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$work/MenuBarIcon.png" Resources/MenuBarIcon.png
echo "wrote Resources/AppIcon.icns and Resources/MenuBarIcon.png"
