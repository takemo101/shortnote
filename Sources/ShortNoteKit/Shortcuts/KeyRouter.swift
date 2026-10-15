import Foundation

/// パネルに届いたキーを、どう扱うかの決定。
enum KeyAction: Equatable {
    /// 何もしない。通常のキー処理（文字入力欄や日本語入力）に任せる。
    case passThrough
    /// 文字入力欄の標準の編集操作。入力中だけ、入力欄へ渡す。
    case textEditing(TextEditingKey)
    /// コマンドを実行する。
    case run(Command)
}

/// 文字入力中に ⌘ で使う標準の編集操作。割り当ては変えられない（予約済み）。
enum TextEditingKey: Equatable {
    case copy, cut, selectAll
}

/// キーの組み合わせと状況から、扱いを決める。画面に依存しないので、単体でテストできる。
enum KeyRouter {
    static func route(_ chord: KeyChord, bindings: KeyBindings, isEditingText: Bool, isComposingText: Bool) -> KeyAction {
        // 日本語入力の変換中は、すべてのキーが入力システムのもの（Esc は変換だけを取り消し、入力中の文字は消さない）。
        if isComposingText { return .passThrough }

        if isEditingText, chord.modifiers == .command, let key = textEditingKeys[chord.keyCode] {
            return .textEditing(key)
        }
        if let command = bindings.command(for: chord, whileEditingText: isEditingText) { return .run(command) }
        return .passThrough
    }

    /// ⌘C / ⌘X / ⌘A のキーコード。
    private static let textEditingKeys: [UInt16: TextEditingKey] = [8: .copy, 7: .cut, 0: .selectAll]
}
