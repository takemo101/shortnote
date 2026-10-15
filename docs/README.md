# ドキュメント案内

ShortNote の補助文書の入口。製品要件・受け入れ条件・対象外の唯一の正本は、ルートの [SPEC.md](../SPEC.md) である。`docs/` は仕様を別管理する場所ではなく、構成の理解・開発手順・検証のために使う。

## 文書の役割

| 文書 | 答えること | 管理しないこと |
|---|---|---|
| [README](../README.md) | どんなアプリか、どう使い、どうビルドするか | 詳細な要件・作業状態 |
| [SPEC](../SPEC.md) | 何を満たすか、何を対象にしないか、受け入れ条件は何か | 検証の成功証拠 |
| [開発規約](../AGENTS.md) | どう調査・変更・検証・文書更新するか | 製品仕様の複製・Issue 状態・作業履歴 |
| [開発手順](development.md) | ビルド・mikan・GitButler・PR・配布物を、どう進めるか | 追加の実施権限・Issue 状態の複製 |
| [構成説明](architecture.md) | Module の責務・状態の所有・座標と倍率・失敗はどう関係するか | 確定 API・実装順序・動作の保証 |
| [参考にした設計原則](references.md) | どの外部の設計原則を選び、何を選ばなかったか。コードのどこに現れるか・レビューで何を問うか | 製品要件・原則の全文の複製 |
| [検証手順と記録](verification.md) | SPEC の条件をどう観測し、何をいつ確認したか、何が人間の確認待ちか | 新しい合格条件・未実施の成功・実施権限 |
| [macOS 共通検証スキル](../.agents/skills/verifying-macos-apps/SKILL.md) | アプリを問わず、実操作・期待値・画像・証拠をどう検証し、何を主張してよいか | 製品仕様・成功履歴・追加の操作権限 |
| [ShortNote 固有レシピ](../.agents/skills/verifying-shortnote/SKILL.md) | 共通手順を、現存する ShortNote のケース・コマンドへどう対応付けるか | 仕様や Issue 状態の複製 |

文書間で矛盾を見つけた場合は、派生文書を根拠に製品要件を変更しない。SPEC の該当節とユーザーの判断を確認し、必要な修正を関係する文書へ反映する。

## 読む順序

- **アプリを知る**：README → SPEC の概要・機能要件・範囲外。
- **作業を始める**：SPEC の対象節 → 開発規約と開発手順 → mikan の対象 Issue → 構成説明の該当 Module → 実際のソース。
- **動作を確かめる**：SPEC の受け入れ条件 → 共通検証スキルと固有レシピ → 検証手順の該当ケース。設計説明だけで動作確認を済ませない。
- **結果を判断する**：検証記録 → SPEC の受け入れ条件。自動の実機観測と、人間の確認を区別する。

## 配置

```text
README.md              概要・使い方・ビルド
SPEC.md                製品要件・受け入れ条件・対象外
AGENTS.md              開発規約
Package.swift          SwiftPM（macOS 13、外部依存なし）
Resources/Info.plist   バンドル設定（LSUIElement・配備下限・アイコン）
Resources/AppIcon.icns アプリのアイコン（scripts/make-icon.sh で生成したもの）
Resources/MenuBarIcon.png メニューバーの単色アイコン（同上）
Sources/ShortNote/     実行ファイル（main.swift だけ）
Sources/ShortNoteKit/  実装（Core・Shortcuts・Render・Platform・UI・App）
Tests/ShortNoteKitTests/ 単体テスト（Swift Testing）
justfile               開発用コマンド（build・run・try・reset-try・package・test・e2e）
scripts/
  build.sh             Universal の ShortNote.app を build/ に作る
  dmg.sh               build/ShortNote.dmg を作る（署名・公証は任意）。VERSION=X.Y.Z で、アプリの版を指定できる
  test.sh              単体テスト（Swift Testing のマクロプラグインのパスを渡す）
  make-icon.sh         アイコンを生成して Resources/ に置く（中で make-icon.swift を実行）
  make-icon.swift      アイコンの描画（CoreGraphics。外部の素材なし）
  verify-dmg.sh        DMG を検査する（整合・中身・アイコン・版・Universal・署名）。ローカルと CI で同じもの
  native-e2e.swift     実機の操作・期待値・ピクセル判定と report
  native-dragsrc.swift ドロップ検証用の、自前のドラッグ元プロセス
.github/workflows/
  release.yml          タグ vX.Y.Z で、DMG をビルドして GitHub Release に添付する（手動実行は、アーティファクトだけ）
.agents/skills/
  verifying-macos-apps/ 他の macOS アプリへ持ち出せる共通検証手順（ambien から取り込み）
  verifying-shortnote/  ShortNote 固有のケース・コマンド・証拠契約
docs/
  README.md            この索引
  development.md       ビルド・mikan・GitButler・配布物
  architecture.md      構成・状態・座標・失敗
  references.md        参考にした設計原則（選択と不採用）
  verification.md      検証手順・記録・人間の確認待ち
```

`.mikan/` は Git 管理外のローカル作業状態で、この配置や文書のリンク先に含めない。Issue の読取り・更新・Report は MCP だけで行い、状態を文書へ複製しない。

現在の文書量では `docs/` 直下に役割別の文書を置き、空のサブディレクトリや重複する索引を作らない。SPEC を移動・分割せず、別の引き継ぎ書も維持しない。計画段階向けの詳細設計・実装計画は、実装済みのため持たない。

## 更新時の扱い

- 製品の意味・数値・範囲を変える場合は、SPEC を正本として扱う。補助文書に同じ値を別管理せず、必要な節へ参照する。
- 構成説明は選択した境界とその理由、検証記録は実際の操作と観測を記す。説明・予定・結果を混ぜない。
- 文書を追加・移動・削除したら、この索引と参照元を同じ変更で更新する。見出しを変えたら、その見出しを参照するリンクも確認する。
- 未実施・失敗・限定的な成功を残す。後の修正や再試行は別の記録として結び付け、過去の証拠を全面的な成功へ書き換えない。
- 利用していないツールの操作手順や架空のコマンドを案内しない。
