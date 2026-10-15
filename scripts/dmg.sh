#!/bin/bash
# build/ShortNote.dmg を作る（ShortNote.app と /Applications へのショートカット入り）。
#
#   ./scripts/dmg.sh                       ad-hoc 署名。手元・身内向け（他の Mac では Gatekeeper の警告が出る）
#   SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#   NOTARY_PROFILE=shortnote-notary ./scripts/dmg.sh
#                                           署名 + 公証 + staple。一般配布向け
#
# NOTARY_PROFILE は事前に一度だけ登録する:
#   xcrun notarytool store-credentials shortnote-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

APP=build/ShortNote.app
DMG=build/ShortNote.dmg
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname ShortNote -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "built: $DMG"
