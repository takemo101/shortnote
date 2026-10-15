# 開発手順

ShortNote の調査・変更・Issue・PR・配布物を、一つの作業単位として進めるための手順。製品仕様ではなく、[AGENTS.md](../AGENTS.md) の規約を具体的な運用へ結び付ける。

## 正本と開始時の読取り順

| 対象 | 正本・役割 |
|---|---|
| 製品要件・受け入れ条件 | [SPEC.md](../SPEC.md) が唯一の正本 |
| 作業規約・操作権限 | [AGENTS.md](../AGENTS.md)。本書はその派生手順であり、追加の実施許可ではない |
| Issue の現在の状態・Report | mikan。文書に Status の写しを維持しない |
| 構成・観測方法・証拠 | [構成説明](architecture.md)、[検証手順と記録](verification.md) |

1. 依頼の対象と、SPEC の該当節（機能要件・受け入れ条件・配布前提）を読む。
2. AGENTS と本書を読み、変更範囲、許可された操作、今回の確認方法を特定する。既存のユーザー変更を保持する。
3. mikan で対象 Issue の本文・現在の Status・関連 Issue・Report を読む。`depends_on` は助言であり、前提達成や承認の代わりではない。
4. 構成説明の該当 Module と、実際のソース・`Package.swift` を読む。

## 作業単位と最小 E2E

一回の作業を、利用者に見える一つの成果と、それを観測する方法で定義する。文書量・試験件数・部品数・PR の数は完成基準にしない。許可された範囲の**最小で安全な端から端までの経路**を早く確かめ、周辺の抽象化や将来対応を先行させない。

- 既存の定義やソースで分かる環境前提を先に読む。調べられる事実はユーザーへ聞かず、設定・権限・鍵・認証を変更して前提不足を勝手に補わない。
- 変更・検証・独立レビュー・文書更新を、一貫した Issue サイズの変更にまとめる。
- 実機試行の前に、仮説・結果を区別できる観測・停止条件を定める。ユーザーへ依頼するときは、画面・操作・期待する可視変化を具体的に示す。
- ユーザー報告は事実として扱う。同じ失敗を確認するだけの再試行や、根拠のない推測修正はしない。

## ビルドと実行

macOS 13 以降、Swift 5.9 以降（Xcode または Command Line Tools）。外部依存はない。

`just` で入口を一覧できる（[justfile](../justfile)）。`just` が無い環境では、同じ処理を `scripts/` から直接実行する。

| レシピ | 内容 |
|---|---|
| `just build` | `./scripts/build.sh`。`build/ShortNote.app`（arm64 + x86_64）を ad-hoc 署名で作る |
| `just run` | ビルドして `open` で起動する。ウィンドウが出て、閉じてもメニューバーに常駐する（再び出すのは ⌃⌥N かメニューバーのアイコン）。常駐中に実行すると、そのウィンドウを出す |
| `just try [画像]` | ビルドして、実行ファイルを端末から起動する。ウィンドウが出て、ログが端末に出る。Ctrl-C で終了する。画像パスを渡すと背景として開く。**常駐中のインスタンスがあると、新しい起動はそちらへ転送して即終了する**（古い常駐を終了してから実行する） |
| `just reset-try` | 書き出し済みの PNG（`/tmp/shortnote/`）と、保存したキャンバスのサイズ・ショートカットの割り当てを消す。ShortNote が持つ状態はこの 2 つ |
| `just package` | `./scripts/dmg.sh`。`build/ShortNote.dmg` を作る（[配布物](#配布物)） |
| `just test` | `./scripts/test.sh`。単体テスト（Swift Testing）を実行する。画面や実入力は使わない。Command Line Tools だけの環境では、`swift test` にマクロプラグインのパスを渡す必要があり、素の `swift test` は失敗することがある |
| `just icon` | `./scripts/make-icon.sh`。`scripts/make-icon.swift` から、`Resources/AppIcon.icns` と `Resources/MenuBarIcon.png` を作り直す。デザインを変えたときだけ実行し、生成物をコミットする。`build.sh` が、これらをアプリの `Contents/Resources/` に入れる |
| `just e2e` | ビルドして native E2E を実行する（[検証の入口](verification.md#検証の入口)）。実行中はマウスとキーボードに触れない |

手で起動する場合：

```sh
open "$PWD/build/ShortNote.app"                              # 起動（相対パスだと見つからない）
open -a "$PWD/build/ShortNote.app" /path/to/image.png        # 画像を背景として開く（起動済みでも、常駐中のウィンドウに入る）
```

- アプリが保存する設定は、キャンバスのサイズ（`canvasWidthPx`・`canvasHeightPx`）と、既定から変えたショートカットの割り当て（`keyBindings`）だけ（`UserDefaults`、bundle ID `dev.takemo101.shortnote`）。書き出し先は固定の `/tmp/shortnote/`。検証では、bundle ID を変えたコピーを使うと、設定も常駐の転送も本番と分かれる（native E2E は、候補のこれらの設定を、実行前に控えて標準へそろえ、終了時に元へ戻す）。
- 常駐中のインスタンスがあると、新しい起動はそちらへ転送して終了する。**検証用に起動する前に、古い候補が残っていないか確認する**（残っていると、新しい候補がウィンドウを出さずに終了する）。確認と終了は、自分が起動した PID を、起動時刻と実行ファイルを照合して行い、名前での一括終了はしない。
- `swift build` のログに `x86_64 architecture is deprecated` の警告が出る。Intel を配布対象から外す判断をするまで、Universal を維持する。

## mikan の Issue 進行

プロジェクトは `shortnote`、Issue prefix は `SNT`。`.mikan/` 全体は Git 管理外のローカル作業状態であり、別の clone へ Issue やボード設定は引き継がれない。配下を直接参照・編集せず、文書のリンク対象にも含めない。Issue の読取り、Status 更新、Report 追加は mikan MCP だけで行う。GitHub Mirrors は別途許可なしに公開しない。

新しい clone で初期化が必要な場合は、ツール導入の権限を確認し、ルートから `mikan init --key SNT --name shortnote` を実行する。既存のローカルボードを上書き・削除しない。

### MCP の入口

利用可能な機能は `search_tools` で発見し、返されたツール名を `get_tool_details` で調べて、入力 schema と分類を確認する。読取り専用であることが明示されている場合だけ `call_read_tool` を使い、更新または未分類のツールは `call_write_tool` から呼ぶ。Issue 取得・Status 更新・Report 追加の具体的なツール名や引数を推測しない。

### 状態と完了条件

実装 Issue は **`backlog → ready → active → completed`** の順で進める。各遷移の直前に MCP で現在の Status を再読取りし、期待する前状態に一致することを確認する。記憶や文書の写しだけで上書きしない。

| Status | 扱い |
|---|---|
| `backlog` | 候補。Issue があるだけでは着手許可にならない |
| `ready` | 対象範囲、前提・依存、SPEC の条件と今回の操作権限を確認済み |
| `active` | 実装直前に移す。同時に active の実装 Issue は最大1件 |
| `blocked` | 未承認、前提不足、検査失敗、未解決レビュー、merge・同期・受け入れの阻害などを理由付きで記録する。解消後は現在状態と再開条件を再確認し、実装は active に戻してから進める |
| `completed` | 必要な検証・レビュー・受け入れ、PR の normal merge、workspace 同期、Report が揃った後にだけ移す |

通常の流れは、実装 → 対象と失敗ケースの検証 → 必要な全体検査（ビルド・native E2E） → 独立レビュー → 指摘修正と影響範囲の再確認 → PR 作成 → `main` へ normal merge → GitButler 同期 → mikan Report → Status 再読取り → `completed`。PR を依頼されていない場合は、無断で commit・push・PR へ進めず、その段階を未達として残す。

検査が失敗、指摘が未解決、PR が未 merge、同期が未完了、受け入れが部分的なら、`active` または理由付き `blocked` を保持し、完成を宣言して次の実装 Issue を開始しない。人間の確認（ホットキー・ペンタブレット等）は別の判断として残り、Issue の完了は製品全体の受け入れではない。

### Report に残すこと

対象と SPEC 節、実行した検査と結果、独立レビューと指摘対応、PR URL・review 済み head・merge commit、同期結果、当該 Issue の受け入れ範囲、未実施事項・制約・blocker を記録する。詳細な実機証拠は [検証記録](verification.md#実施記録) へリンクし、製品要件や Status の写しを増やさない。実行していないコマンドや観測結果を、成功として置かない。

## GitButler と PR の一連の手順

Git の書込みは `but` を使う。統合先は `main`、GitButler target は `origin/main`、push remote は `origin`。feature・fix は Issue 単位の専用 branch／stack で扱い、無関係な変更を混ぜない。`develop` を新設せず、target の変更を勝手に行わない。

操作前に対象が ShortNote のルートであることを確認し、インストール済み `but` skill を読む。読取り専用の Git 調査は可能だが、raw Git の add・commit・checkout・merge・rebase・push などで書き込まない。GitButler の設定・認証が足りない場合は blocker とし、raw Git やグローバル設定変更へ逃げない。

### 必要最小限の inspect

- 未 commit の変更を選ぶなら `but diff`。branch／stack の配置や conflict が判断に必要なら `but status`。
- ファイル／hunk ID や commit 内の詳細が必要なときだけ `but status -fv`。既知の branch／commit の詳細は `but show <id>`。
- 目的なしに status を繰り返さない。ID は現在の出力からコピーし、推測しない。

### このリポジトリの GitButler 設定（初期化時の事実）

初期化は `but setup --init`、公開は `gh repo create takemo101/shortnote --public --source . --remote origin` で行った。次の点は、設定を作り直すときに再び問題になる。

- `but setup` は、push 先が無いと `gb-local`（ローカル専用の remote）を作る。`origin` を足した後に、`but config push-remote origin` と `but config target origin/main` で切り替える。これを怠ると、`but push` は GitHub に届かず `gb-local` へ送られる。
- `but config target` は、適用済みの branch があると拒否される。
- **`but unapply <branch>` は、その stack のファイルを作業ツリーから外す。** 唯一の stack を unapply すると、ソースが一時的に消えたように見える（commit は残る）。復旧は、target に含まれていれば `but pull`、そうでなければ `but apply <branch>`。target を切り替える前に、未 push の commit が無いことを確認する。
- target を `origin/main` に切り替えた後は、`but apply main` が `Cannot add the target 'refs/heads/main' branch to its own workspace` で拒否された（commit が `origin/main` に含まれているとき）。この場合は `but pull` で作業ツリーが戻る。

### PR 依頼時の standing lifecycle

ユーザーが PR を依頼した場合は、**検証・独立レビュー → scoped commit → PR 作成 → `main` への normal merge → workspace 同期 → Report と Issue 完了**を一連で行う。その依頼の範囲で必要な branch・commit・push・PR・通常 merge・同期を、各段階で再承認を求めず進める。draft、review-only、no-merge、別 target の明示依頼は優先する。PR 依頼がなければ、現在の変更を無断で commit・push・PR 化しない。

1. 対象 diff を読み、関係する検証と独立レビューを済ませ、指摘を解消する。必要なファイル／hunk だけを `but commit -b <branch> -m <message> <ids...>` で選ぶ。Issue に結び付く branch 名を使い、既存の無関係な変更を取り込まない。
2. `but pr new <branch> -F <message-file>` で PR を作る。この操作は push を含む。作成された PR の実際の target、head SHA、変更ファイルを読む。
3. required checks、必要な reviews、mergeability を確認する。head が変わったなら、以前のレビュー・検証を新 head の承認としない。未達・失敗・conflict があれば merge せず blocker を残す。
4. 適用可能な GitButler の PR merge 操作があればそれを使う。利用できるのが auto-merge 操作だけで、GitHub auto-merge が無効／利用不可の場合に限り、`gh pr merge <number> --repo takemo101/shortnote --merge --match-head-commit <reviewed-head-sha>` を PR merge 段階の例外として使う。review 済み head に束縛し、target は `main` のままにする。
5. GitHub の実際の PR 状態で `MERGED` と merge commit を確認する。成功らしい CLI 表示、auto-merge の予約、ユーザー報告だけで merge 済みとしない。
6. `but pull --check`、続けて `but pull --status-after` を実行して workspace を同期する。merge commit が workspace に含まれることと残る変更を確認する。conflict を reset・discard・強制同期で消さず、無関係な作業を保つ。
7. PR URL、merge commit、同期結果、残る変更・制約を報告し、mikan Report に記録する。受け入れが揃ったことを確認し、Status を再読取りしてから `completed` へ進める。

「一連で行う」は assistant が手順を完了する意味であり、GitHub の auto-merge 設定を有効化する指示ではない。`--admin`、force push、checks・reviews・branch protection の迂回、`but land` による PR 回避、auto-merge 設定変更、リポジトリの公開範囲変更、mikan mirror 公開は禁止する。これらの権限や、実装・署名・配布の権限を、PR 依頼から推測しない。

## 検証コマンド

ビルドと実機検証の入口は [検証手順](verification.md#検証の入口) にある。ビルドの成功は動作の証明ではない。自動の実機観測（native E2E）と人間の確認を混同せず、結果は [実施記録](verification.md#実施記録) の形式で残す。

## 配布物

- `./scripts/dmg.sh` が `build/ShortNote.dmg`（`ShortNote.app` と `/Applications` へのショートカット入り）を作る。既定は ad-hoc 署名。`build/` は Git 対象外。
- Developer ID 署名・公証は、`SIGN_IDENTITY`／`NOTARY_PROFILE` を渡したときだけ走る。**この経路は証明書が無いため一度も実行しておらず、動作は未確認**。実施の可否は SPEC の [配布前提](../SPEC.md#10-配布前提) とユーザーの判断に従う。
- GitHub Releases への公開は、次の「リリースの手順」で行う（SPEC の [GitHub Releases での配布](../SPEC.md#101-github-releases-での配布)）。

### リリースの手順

`.github/workflows/release.yml` が、タグ `vX.Y.Z` の push で、DMG をビルドして GitHub Release に添付する。**リリースの公開は、ユーザーの依頼があったときだけ行う。依頼なしにタグを作らない。**

1. **版を上げる**：`Resources/Info.plist` の `CFBundleShortVersionString` と `CFBundleVersion` を、リリースする `X.Y.Z` にして、PR で `main` に入れる（版の信頼できる元は、ソースの `Info.plist`。タグと一致しないと、ワークフローが Release を作らずに失敗する）。
2. **タグを作る**：版を入れた `main` の commit に、タグ `vX.Y.Z` を作る。ユーザーが自分の端末で `git tag vX.Y.Z <main の commit> && git push origin vX.Y.Z` としてもよい。エージェントが依頼を受けて作るときは、`but` にタグの操作がなく、raw Git で書き込めないので、GitHub の API でサーバー側に作る：`gh api repos/takemo101/shortnote/git/refs -f ref=refs/tags/vX.Y.Z -f sha=<main の commit の SHA>`。軽量タグで、push のイベントが通常どおり発火する。
3. ワークフローが、単体テスト → `VERSION=X.Y.Z ./scripts/dmg.sh` → `./scripts/verify-dmg.sh`（整合・中身・アイコン・版・Universal・署名）→ `ShortNote-X.Y.Z.dmg` と `.sha256` の作成、の順に進む。次に、公開のジョブが、ダウンロードしたファイルの SHA-256 を照合し、通ったときだけ Release を作る。Release のノートには、インストールと Gatekeeper の回避手順を付け、変更点は GitHub が生成する。
4. タグを打たずに確かめたいときは、Actions タブ → release → Run workflow（`workflow_dispatch`。ワークフローが `main` に入ってから使える。タグを選んで起動しても、Release は作らない）。DMG をアーティファクト（14 日）に残し、`handoff` ジョブが、Release のジョブと同じ手順で、アーティファクトをダウンロードして SHA-256 を照合する。リリースに関わるファイル（ワークフロー、ビルド・DMG・検査・テストのスクリプト、`Package.swift`、`Resources/`）を変える Pull Request でも、同じドライランが自動で走る（マージ前に、ワークフロー自体を検証できる）。

署名は ad-hoc のまま。署名・公証の鍵や認証情報を、ワークフローに渡さない。ローカルで同じ検査をするには、`VERSION=X.Y.Z ./scripts/dmg.sh && ./scripts/verify-dmg.sh build/ShortNote.dmg X.Y.Z`。
