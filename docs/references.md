# 実装の参考資料

実装とレビューで使う設計原則の選択。製品要件の正本は [SPEC.md](../SPEC.md)、構成は [構成説明](architecture.md)、検証は [検証手順と記録](verification.md)。ここに書いた原則は、設計判断の材料であり、ビルド成功・実機動作・実施権限の証拠にならない。

## 出典と扱い

- 参照元：[j5ik2o/okite-ai](https://github.com/j5ik2o/okite-ai) の `skills/`。固定した改訂は `f1bc1c37831cbe5ea6a9da5e8f828e639a143e32`。ライセンスは MIT。
- 以下は ShortNote 向けの要約と判断で、資料の全文・コード例・skills 自体を転載・導入するものではない。この文書を第三者へ再配布する場合は、MIT の著作権表示とライセンス文を確認する。
- 原典の例は Rust・Java・Scala などで書かれている。言語に依らない原則だけを、Swift / AppKit の言葉に直して使う。
- 対象は、約 2 千行、単一プロセス、DB もネットワークもなく、ウィンドウが 1 つのアプリ。**規模に見合わない儀式は持ち込まない。**
- 原典のうち、集約・CQRS・イベントソーシング・リポジトリ・Pekko・OpenSpec・リンター作成の skills は読まず、対象外にした。

## 選んだ原則

| 原則（skill） | 判断 | ShortNote での適用 | レビュー質問 |
|---|---|---|---|
| 変更理由で境界を決める（`package-design`） | 部分採用 | 変更理由は 4 つに分ける：① 描画・モデルの規則、② 入力（ポインタ・キー）、③ OS との接点（ペーストボード・ファイル選択・`UserDefaults`・PNG 書き出し）、④ AppKit の見た目。依存は一方向（UI → 規則、OS との接点 → 規則）。規則側は AppKit を `import` しない。`utils`・`helpers` を作らない | この diff で触った型の、変更理由は 1 つか。規則側に `import AppKit` が増えていないか |
| 境界で一度だけ型にする（`parse-dont-validate`） | 採用 | 外から入る値は、入口で一度だけ検証済みの型にして、中は型を信頼する。`CanvasSize.parse`（偶数・最小・最大・画面に収まる）、`KeyChord`（イベントから）、保存した設定の読み込み、画像の取り込み。壊れた保存値は握りつぶさず、理由を返す | 検証したあとも、生の `Int`・`String` を使い続けていないか。`Bool` を返す `check` 関数が増えていないか |
| 常に有効な値（`domain-primitives-and-always-valid`） | 部分採用 | 幅と高さは不可分なので `CanvasSize` にまとめ、無効なサイズ（奇数・最小未満）を作れないようにする。`KeyChord` も、同じキーが別の値にならないよう正規化する | 無効な状態を、この型の初期化で作れてしまわないか |
| ラップする基準（`when-to-wrap-primitives`） | 採用 | 新しい型を作る前に、5 つの基準（不変条件、取り違えやすさ、操作の置き場、複数値の不可分性、使われる箇所の多さ）のうち 2 つ以上を満たすか確かめる。ラップするのは `CanvasSize`、`KeyChord`、`Command`（閉じた集合）。色・線幅・座標・ファイル名は素のまま | この型は、基準のうち少なくとも 2 つを満たすか。ただの入れ物になっていないか |
| 集合に固有の規則を持つ型（`first-class-collection`） | 部分採用 | 規則（競合の禁止、上限、巻き戻し）がある集合だけを型にする：`KeyBindings`（競合検出、既定値と上書き、逆引き）、`History`（積む・戻す・やり直す、上限）。`[Item]` は、同じ操作が 2 か所以上に出るまで `Document` のメソッドで足りる | コレクションを外から直接 `append`・`remove` して、規則を迂回していないか |
| 命じる（`tell-dont-ask`） | 部分採用 | 状態を持つ規則側の型（`Document`、`History`、`KeyBindings`）に、操作（`appending`、`translatingItem`、`assigning`）を置く。外で読んで `if` で判断し、同じ物を更新する形にしない。描画と書き出しは読み取りなので許す | 他の型のプロパティを読んで判断し、同じ型を更新していないか |
| 窓口だけを呼ぶ（`law-of-demeter`） | 部分採用 | 機械的には守らない。別モジュールの内部を 2 段以上たどる呼び出しを避ける（`panel` は `KeyBindings` の辞書を知らず、`ShortcutCenter` の解決だけを呼ぶ）。`NSEvent`・`NSPasteboard` の連鎖は、入口（`KeyChord(event:)`、`ImageIntake`）で 1 回だけたどる | この行は、別モジュールの内部を 2 段以上たどっていないか |
| 目的が同じものだけ共通化する（`intent-based-dedup`） | 採用 | ショートカットとツールバーのボタンは、同じ `Command` を実行する（目的が同じ）。画像の取り込みは、ペースト・ドロップ・ファイル選択が同じ入口を通る。一方、画面の描画と PNG 書き出しは、同じ描画を通すが、将来の変更理由（選択の装飾など）が違うので、入口を分けておく。汎用の `Helpers`・`Util` は作らない | この共通化は、変更理由が同じ 2 か所をまとめているか。たまたま同じコードではないか |
| 回復できる失敗は型にする（`error-handling`） | 採用 | 利用者や環境のせいで起こる失敗は、`Result`・`throws` と小さな `enum` にする（`CanvasSizeError`、`KeyBindings.AssignError`、`ExportError`）。表示（`NSAlert` など）は、呼び出し側の UI だけが決める。契約違反は `precondition`。`try?` や黙った `return` で失敗を消さない | 失敗しうる処理が、黙って消えていないか |
| 失敗の分類（`error-classification`） | 部分採用 | 語彙として 2 つだけ使う：Error（利用者・環境起因。画面が小さい、ディスクに書けない、画像が壊れている）と Defect（コード起因。不正な状態）。保存した設定の破損だけは、起動時に既定値へ戻して理由を示す（クラッシュしない）。隔離・再起動・冗長化は持ち込まない | この失敗は、環境のせいで起こりうるものか、バグか。それに合う扱いか |
| 純粋な核を先にテストする（`domain-model-first`） | 部分採用 | 順序だけ採る：履歴、サイズの検証、ショートカットを、AppKit 抜きのテストで先に固め、そのあとで描画・OS との接点・UI をつなぐ。リポジトリ・ユースケース層・DDD の部品は採らない | この振る舞いは、AppKit 抜きのテストで表現できているか |
| 構造を動かす手順（`refactoring-packages`） | 部分採用 | 動かす前に、今の振る舞いをテストと実機の E2E で固める。コミットは「移動だけ」か「振る舞いの変更」のどちらかに絞る。深さ・ファイル数の目安は採らない | このコミットは、移動だけか、振る舞いの変更か。どちらかに絞られているか |
| 保存形式の互換（`backward-compat-governance`） | 部分採用 | 公開 API や外部クライアントはないので、制度は持たない。利用者のマシンに残る `UserDefaults` の形式だけ、読み込みを 1 か所に集め、旧い形式の分岐を散らさない。新しい保存形式（ショートカットの上書き）には、最初から互換の層を作らない | 保存データの読み書きに、互換の分岐が増えていないか。増えるなら 1 か所か |

## 持ち込まないもの

- **DDD の語彙と部品**（Entity・Aggregate・Domain Service・Bounded Context）。`Document`・`Item`・`History` は普通のモデル型で足りる。
- **リポジトリ、4 層構成、Output Port、UseCase クラス**（`clean-architecture`、`repository-*`）。層の数だけ型とファイルが増え、1 ウィンドウのアプリでは儀式のコストが勝つ。
- **すべてのプリミティブのラップ**。不変条件も取り違えもない値は、素のままにする。
- **全型の protocol 化**。差し替えが実際に要る箇所（保存先、時計）が出るまで、具象型で持つ。
- **`breachEncapsulationOf…` のような命名規約**（`breach-encapsulation-naming`）。getter を絞る狙いは `tell-dont-ask` で足りる。
- **Fault・Failure の隔離・再起動・冗長化**（`error-classification` の後半）。単一プロセスで、対象になる外部サービスがない。
- **数値の目安**（凝集・結合のメトリクス、「7 個前後」、ディレクトリの深さ、ファイル数）。1 〜 2 千行では測る意味がなく、数合わせが目的になる。
- **非推奨化の周期・利用率の計測・撤去の期限**。利用者が自分だけで、計測の手段もない。
- **`Result` / `Either` の外部ライブラリ**。標準の `Result` と `throws` で足りる。
- **PR の運用の自動化**（`pr-green`）。設計の原則ではなく運用の話。運用は [開発手順](development.md) に従う。

## 適用の順序

1. 今の振る舞いを固定する：実機の native E2E（A01〜A13）が全件 pass の状態を起点にする。
2. 規則を AppKit から切り出す：`Item`・`Document`・`History` を、`CoreGraphics` だけに依存させる（`tell-dont-ask`、`package-design`）。
3. `CanvasSize` を作る：検証を 1 か所に集め、UI は検証済みの値だけを受け取る（`parse-dont-validate`、`domain-primitives-and-always-valid`）。
4. `KeyChord`・`Command`・`KeyBindings` を作る：ショートカットとツールバーが同じ `Command` を実行する（`first-class-collection`、`intent-based-dedup`）。
5. OS との接点を、入口に集める：`ImageIntake`、PNG の書き出し、`UserDefaults` の読み書き（`parse-dont-validate`、`law-of-demeter`、`backward-compat-governance`）。
6. 失敗の扱いを揃える：`try?` と黙った `return` を洗い出し、`Result`・`throws` にして、表示は UI だけが決める（`error-handling`、`error-classification`）。
7. 残った View・Controller を薄く保つ（`law-of-demeter`、`tell-dont-ask`）。

実際の対応（どの型がどの原則に従い、どこに置かれたか）は [構成説明](architecture.md) に書く。
