# ShortNote の開発用コマンド。`just` で一覧を表示する。

app := justfile_directory() / "build/ShortNote.app"
exe := app / "Contents/MacOS/ShortNote"

# 書き出し先（アプリ固定）。ShortNote が持つ唯一の状態
notes_dir := "/tmp/shortnote"

default:
    @just --list

# Universal（arm64 + x86_64）の ShortNote.app を build/ に作る（ad-hoc 署名）
build:
    ./scripts/build.sh

# ビルドして、普段どおり起動する。メニューバーに常駐し、ウィンドウは出さない（出すのは ⌃⌥N かメニューバーのアイコン、または 2 回目の `just run`）
run: build
    open "{{app}}"

# ビルドして、実行ファイルを前面で起動する（ログが端末に出る。Ctrl-C で終了）。画像パスを渡すと背景として開く。常駐中のインスタンスがあると、転送して即終了する
try *image: build
    "{{exe}}" {{image}}

# 書き出し済みの PNG を消して、初回の状態に戻す
reset-try:
    rm -rf '{{notes_dir}}'

# build/ShortNote.dmg を作る（署名・公証は SIGN_IDENTITY / NOTARY_PROFILE を渡したときだけ。scripts/dmg.sh を参照）
package:
    ./scripts/dmg.sh

# 実機の native E2E を実行する（マウスとキーボードに触れない。検証手順は docs/verification.md）
e2e: build
    /usr/bin/swift scripts/native-e2e.swift "{{exe}}" --artifacts "{{justfile_directory()}}/build/native-e2e"
