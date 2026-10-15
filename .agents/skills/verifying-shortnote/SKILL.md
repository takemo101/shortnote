---
name: verifying-shortnote
description: Use when ShortNote の native E2E、ホットキー・ペンタブレット・色選択・ドラッグで渡す動作の人間確認の依頼、実行元の権限不足・許可反映、フォーカス喪失、ツール・取り消し・文字入力・画像の貼り付け／ドロップ・移動・書き出し・背景透過・二重起動の転送の検証、DMG・配布物の検証、または固有の検証コマンドと受け入れ条件を確認するとき。
---

# ShortNote 固有の検証レシピ

**必須スキル：verifying-macos-apps**。まず [macOS 共通手順](../verifying-macos-apps/SKILL.md)（本体と、必要な `references/`）を読み、このレシピで対象・ケース・観測契約を対応付ける。要件・受け入れ・実施権限の唯一の正本はプロジェクト root の `SPEC.md`。`AGENTS.md`、`docs/verification.md`、対象の現存実装も確認する。

## 実在する入口

リポジトリ root で実行する。

```sh
./scripts/build.sh
/usr/bin/swift scripts/native-e2e.swift "$PWD/build/ShortNote.app/Contents/MacOS/ShortNote" \
  --artifacts "$PWD/build/native-e2e"
```

引数は実行ファイルと `--artifacts` だけ（実行ファイルが無い、または `-` で始まる引数だと usage を出して終了コード 2）。ケースの選択はなく、全ケースを一度に実行する。存在しない flag やケース名を発明しない。

| 対象 | ケース | SPEC の条件と実観測 |
|---|---|---|
| 起動・窓・Dock | C0, C1, C2, C14 | A01／起動した PID と実行ファイルの同定、パネルの出現、activationPolicy、Esc で隠れる |
| CLI の画像・二重起動の転送 | C3, C17 | A05／窓キャプチャで背景が出る。2 回目の起動が終了し、常駐側が新しい画像に切り替わる |
| ツールと描画 | C4, C6〜C9, T1, M1 | A03／AX で操作部品に到達、実ポインタの筆跡・図形・ブラシサイズ、文字ツール、移動 |
| 取り消し／やり直し | C10〜C13, M2, M3 | A04／4 つのキー操作で、直前の要素だけが戻る・やり直される |
| 文字入力 | T1, T2, T2a, T3 | A06／入力欄の出現、実キーの到達、確定で書き出しに出る、Esc は入力だけを取り消す |
| 画像の貼り付け・ドロップ | P1, D1 | A05／Cmd+V で中央に 70%、自前のドラッグ元からのドロップで、ドロップ位置を中心に置く |
| 書き出し・透過・パス | C5, C5b, C15, C16 | A07, A08／新しい実在の PNG のパス、画素の一致、アルファ |

ケースの観測・示さないことの詳細は [検証手順](../../../docs/verification.md#ケースと受け入れ条件)。

## 権限準備と未完ケースへの復帰

手動の準備先・設定項目・拒否の尊重・再起動条件は、共通スキルの [preflight-and-permissions](../verifying-macos-apps/references/preflight-and-permissions.md) に従う。許可の対象は、実際の実行元（ターミナル・IDE など）で、ShortNote 自身ではない。実行元の終了・再起動と OS 設定の操作は、ユーザー本人が行う。

事前確認は、SDK の非プロンプトの読取りを、実行元と同じ経路で行う。

```sh
/usr/bin/swift -e 'import CoreGraphics; import ApplicationServices; print("AX", AXIsProcessTrusted(), "post", CGPreflightPostEventAccess(), "capture", CGPreflightScreenCaptureAccess())'
```

false のものがあれば、該当ケースは blocked であり、AI が TCC・OS の設定を変えて補わない。許可が通ったら、有効な既存の証拠（同じビルドの sha256）を繰り返さず、未完のケースを新しい run で実行する。権限成功後のフォーカス不一致を、権限不足へ戻さない。

## 実行時の注意

- **多重起動**：ShortNote は、同じ bundle ID の実行中インスタンスがあると、新しい起動を転送して終了する。**実行前に、このリポジトリの旧い候補が残っていないか確認する**。残っていると、候補がウィンドウを出さずに終了し、C1 が fail する。残りは、起動時刻と実行ファイルを照合してから、その PID だけを終了する。名前での一括終了はしない。
- **書き出し先**：アプリの固定の `/tmp/shortnote/`。ハーネスは、自分が起動して生じた新しいファイルだけを読む。ユーザーの書き出し済みファイルを消さない。
- **クリップボード**：パスのコピーを観測するため、実行中に上書きされる。終了時に、元の文字列だけを戻す。実行前に、残したい画像などがクリップボードにないことを確認する。
- **ポインタとキーボード**：実行中は物理のポインタとキーを使う。ユーザーは触れない。ほかの検証・probe と同時に実行しない。
- **ドロップ**：ハーネスが `scripts/native-dragsrc.swift` をコンパイルして、自前の GUI プロセスを起動し、そこからドラッグする。コンパイルできないとき（root 以外で実行した等）は、D1 と、それに依存する M1〜M3 が blocked になる。他アプリのウィンドウを使わない。
- **ログ**：候補の標準エラーは run の `cand.log`。

## runner 固有の証拠契約

stdout の今回の report path を読む。`schema_version:1`、`executable`、`binary_sha256`、`finished_at`、`checks[].id/status/observed` を確認する。

終了コードは fail=1、blocked=77、全 pass=0。優先順は fail > blocked > pass。途中までの pass を全体の合格にしない。blocked を pass にしない。

## runner の外の確認（probe）

ハーネスは、見た目（ツールバーのレイアウト・色・描画の質）と、操作の実感を見ない。共通スキルの [probes](../verifying-macos-apps/references/probes.md) と `scripts/native-probe.swift` で、窓の一覧・境界・AXPress を測れるが、見た目の好みは人間が判断する。結果は runner の pass とは別の証拠として、[検証記録](../../../docs/verification.md#実施記録) に残す。

## 個別に残す受け入れ

⌃⌥N の全域ショートカット、ペンタブレットの筆圧、色選択、他アプリへの「ドラッグで渡す」、日本語 IME での変換入力、文字入力中の Cmd+V／Cmd+Z、起動の速さ、x86_64 での実行、Gatekeeper の実際の警告は、AI が合格にしない。具体的な操作と期待する変化は [人間の確認](../../../docs/verification.md#人間の確認) に従って、ユーザーに依頼する。実行記録と未確認範囲は `docs/verification.md`、Issue 状態は mikan で確認し、このレシピに複製しない。
