# ShortNote の開発用コマンド。`just` で一覧を表示する。

set positional-arguments

app := justfile_directory() / "build/ShortNote.app"
exe := app / "Contents/MacOS/ShortNote"

# 書き出し先（アプリ固定）と、設定の保存先（キャンバスのサイズだけを保存する）。ShortNote が持つ状態はこの 2 つ
notes_dir := "/tmp/shortnote"
bundle_id := "dev.takemo101.shortnote"

default:
    @just --list

# Universal（arm64 + x86_64）の ShortNote.app を build/ に作る（ad-hoc 署名）
build:
    ./scripts/build.sh

# ビルドして、普段どおり起動する。ウィンドウが出て、閉じてもメニューバーに常駐する（再び出すのは ⌃⌥N かメニューバーのアイコン）。常駐中の旧いインスタンスがあると、それが前面に出るだけで新しいビルドにならない（先に終了する）
run: build
    open "{{app}}"

# ビルドして、実行ファイルを端末から起動する（ウィンドウが出て、ログが端末に出る。Ctrl-C で終了）。画像パスを渡すと背景として開く。常駐中のインスタンスがあると、転送して即終了する
try *image: build
    "{{exe}}" "$@"

# 書き出し済みの PNG と、保存したキャンバスのサイズを消して、初回の状態に戻す（インストール済みの ShortNote の保存サイズも消える）
reset-try:
    rm -rf '{{notes_dir}}'
    -defaults delete {{bundle_id}} canvasWidthPx
    -defaults delete {{bundle_id}} canvasHeightPx

# build/ShortNote.dmg を作る（署名・公証は SIGN_IDENTITY / NOTARY_PROFILE を渡したときだけ。scripts/dmg.sh を参照）
package:
    ./scripts/dmg.sh

# 実機の native E2E を実行する。bundle ID を変えたコピーで走るので、常駐中の ShortNote と保存サイズには触れない。実行中はマウスとキーボードに触れない（検証手順は docs/verification.md）
e2e: build
    ./scripts/e2e.sh
