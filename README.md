# ShortNote

付箋のように小さな、メニューバー常駐のペイントツール（macOS）。手書きでアイデアをさっとスケッチして、その画像の**ファイルパス**をコーディングエージェントに渡すためのもの。

ショートカット一発でウィンドウが出て、描いて、パスをコピーするかドラッグするだけ。設定は要りません。

## 使い方

| 操作 | 方法 |
|---|---|
| ウィンドウを出す | `⌃⌥N`（メニューバーのアイコンからも開けます） |
| 描く | ペン／円／四角。マウス・トラックパッド・ペンタブレット（筆圧対応） |
| 文字を書く | 文字ツールでクリック → 入力。`Return` で確定、`Shift+Return` で改行、`Esc` で取り消し |
| 画像を足す | `Cmd+V` で貼り付け、またはキャンバスへドラッグ＆ドロップ（ドロップ位置が中心） |
| 動かす | 移動ツールで画像・文字・図形をドラッグ |
| 取り消し／やり直し | `Cmd+Z` / `Cmd+Shift+Z`（`Ctrl+Z` / `Ctrl+Shift+Z` も可） |
| 閉じる | `Esc` |
| パスを渡す | 「パスをコピー」、または「ドラッグで渡す」をエージェントの入力欄へドラッグ |

- 書き出し先は `/tmp/shortnote/note-<日時>.png`（PNG）。「背景透過」をオンにすると透明背景で書き出します。
- 画像を開いて始めたいときは、引数で渡します。

  ```sh
  open -a ShortNote --args /path/to/image.png
  ```

  起動済みの場合は、常駐中のウィンドウに画像が読み込まれます。

## ビルド

macOS 13 以降、Swift 5.9 以降（Xcode または Command Line Tools）が必要です。

```sh
./scripts/build.sh    # build/ShortNote.app（arm64 + x86_64 の Universal）
./scripts/dmg.sh      # build/ShortNote.dmg
```

`dmg.sh` は既定で ad-hoc 署名です。他の Mac では Gatekeeper に止められるので、右クリック →「開く」、または次のコマンドで検疫属性を外します。

```sh
xattr -dr com.apple.quarantine /Applications/ShortNote.app
```

Developer ID で署名・公証する場合は、スクリプト冒頭のコメントを参照してください。

## 仕様

[menubar-paint-spec.md](menubar-paint-spec.md)
