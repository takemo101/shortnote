#!/bin/bash
# ビルドした DMG を、公開の前に検査する（ローカルでも、リリースのワークフローでも、同じもの）。
#
#   ./scripts/verify-dmg.sh build/ShortNote.dmg [期待する版 X.Y.Z]
#
# 検査：DMG の整合、中身（アプリ・/Applications へのリンク・アイコン）、アプリの版（指定したとき）、
#       arm64 と x86_64 の両方を含む、署名の整合。ひとつでも失敗したら、終了コード 1。
# DMG を読み取り専用でマウントして調べ、終わったら必ずデタッチする。
#
# 注意：macOS 標準の bash 3.2 は、EXIT トラップがあると、未定義変数などの致命的なエラーの終了コードを 0 にしてしまう。
# 検査が失敗を握りつぶさないよう、検査はサブシェルで走らせ、後始末は、その終了コードを保存してから行う（EXIT トラップは使わない）。
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <dmg> [version]}"
EXPECTED_VERSION="${2:-}"

fail() { echo "verify-dmg: FAIL: $*" >&2; exit 1; }
ok() { echo "verify-dmg: ok: $*"; }

[ -f "${DMG}" ] || fail "DMG が無い: ${DMG}"
MOUNT="$(mktemp -d)"

checks() {
    hdiutil verify "${DMG}" >/dev/null 2>&1 || fail "hdiutil verify が通らない"
    ok "DMG の整合（hdiutil verify）"

    hdiutil attach "${DMG}" -readonly -nobrowse -noverify -mountpoint "${MOUNT}" -quiet >/dev/null 2>&1 || fail "マウントできない"
    local app="${MOUNT}/ShortNote.app"

    [ -d "${app}" ] || fail "ShortNote.app が DMG に無い"
    [ -L "${MOUNT}/Applications" ] && [ "$(readlink "${MOUNT}/Applications")" = "/Applications" ] || fail "/Applications へのリンクが無い"
    ok "中身（ShortNote.app、/Applications へのリンク）"

    local plist="${app}/Contents/Info.plist"
    local icon_name
    icon_name="$(plutil -extract CFBundleIconFile raw "${plist}" 2>/dev/null || true)"
    [ -n "${icon_name}" ] || fail "Info.plist に CFBundleIconFile が無い"
    [ -f "${app}/Contents/Resources/${icon_name}.icns" ] || fail "アイコン ${icon_name}.icns が無い"
    [ -f "${app}/Contents/Resources/MenuBarIcon.png" ] || fail "メニューバーのアイコン MenuBarIcon.png が無い"
    ok "アイコン（${icon_name}.icns、MenuBarIcon.png）"

    if [ -n "${EXPECTED_VERSION}" ]; then
        local short build
        short="$(plutil -extract CFBundleShortVersionString raw "${plist}")"
        build="$(plutil -extract CFBundleVersion raw "${plist}")"
        [ "${short}" = "${EXPECTED_VERSION}" ] || fail "アプリの版 ${short} が、期待する ${EXPECTED_VERSION} と違う"
        [ "${build}" = "${EXPECTED_VERSION}" ] || fail "CFBundleVersion ${build} が、期待する ${EXPECTED_VERSION} と違う"
        ok "アプリの版 ${short}"
    fi

    local archs
    archs="$(lipo -archs "${app}/Contents/MacOS/ShortNote")"
    case " ${archs} " in *" arm64 "*) ;; *) fail "arm64 を含まない（${archs}）" ;; esac
    case " ${archs} " in *" x86_64 "*) ;; *) fail "x86_64 を含まない（${archs}）" ;; esac
    ok "Universal（${archs}）"

    codesign --verify --deep --strict "${app}" >/dev/null 2>&1 || fail "codesign --verify が通らない"
    ok "署名の整合（codesign --verify --deep --strict）"
}

set +e
( set -e; checks )
rc=$?
set -e

hdiutil detach "${MOUNT}" -quiet >/dev/null 2>&1 || hdiutil detach "${MOUNT}" -force -quiet >/dev/null 2>&1 || true
rmdir "${MOUNT}" 2>/dev/null || true

if [ "${rc}" -ne 0 ]; then
    echo "verify-dmg: FAILED (exit ${rc}): ${DMG}" >&2
    exit "${rc}"
fi
echo "verify-dmg: all checks passed: ${DMG}"
