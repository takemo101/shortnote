import Foundation

/// コマンドとキーの割り当て。既定値との差分（overrides）だけを保持する。
struct KeyBindings: Equatable {
    private static func chord(_ code: UInt16, _ mods: KeyModifiers, _ label: String) -> KeyChord {
        KeyChord(keyCode: code, modifiers: mods, label: label)
    }

    private static func chord(_ code: UInt16, _ label: String) -> KeyChord {
        KeyChord(keyCode: code, label: label)
    }

    static let defaults: [Command: [KeyChord]] = [
        .showPanel: [chord(45, [.control, .option], "N")],
        .hidePanel: [chord(53, "Esc")],
        .undo: [chord(6, .command, "Z"), chord(6, .control, "Z")],
        .redo: [chord(6, [.command, .shift], "Z"), chord(6, [.control, .shift], "Z")],
        .pasteImage: [chord(9, .command, "V")],
        .openImage: [chord(31, .command, "O")],
        .copyPath: [chord(8, [.command, .shift], "C")],
        .toolPen: [chord(18, "1")],
        .toolEllipse: [chord(19, "2")],
        .toolRect: [chord(20, "3")],
        .toolText: [chord(21, "4")],
        .toolMove: [chord(23, "5")],
        .brushSmaller: [chord(33, "[")],
        .brushLarger: [chord(30, "]")],
    ]

    /// OS やテキスト編集の標準動作と衝突するため割り当て不可のキー。
    static let reservedChords: Set<KeyChord> = [
        chord(8, .command, "C"), chord(7, .command, "X"), chord(0, .command, "A"),
        chord(12, .command, "Q"), chord(4, .command, "H"), chord(46, .command, "M"),
        chord(13, .command, "W"), chord(43, .command, ","),
        chord(49, .command, "Space"), chord(48, .command, "Tab"),
    ]

    /// 既定との差分。空配列は「意図的に未割り当て」。
    private(set) var overrides: [Command: [KeyChord]]

    init(overrides: [Command: [KeyChord]] = [:]) {
        self.overrides = overrides
    }

    func chords(for command: Command) -> [KeyChord] {
        overrides[command] ?? Self.defaults[command] ?? []
    }

    func isCustomized(_ command: Command) -> Bool {
        guard let override = overrides[command] else { return false }
        return override != (Self.defaults[command] ?? [])
    }

    var hasCustomizations: Bool {
        Command.allCases.contains { isCustomized($0) }
    }

    /// 有効な割り当てから chord に一致するコマンドを返す。
    /// テキスト入力中は入力と衝突しない（isTypingSafe な）キーだけが対象。
    func command(for chord: KeyChord, whileEditingText: Bool) -> Command? {
        if whileEditingText && !chord.isTypingSafe { return nil }
        return Command.allCases.first { chords(for: $0).contains(chord) }
    }

    enum AssignError: Error, Equatable {
        case conflict(Command)
        case reserved
        case globalNeedsModifier
    }

    /// command の割り当てを [chord] に置き換える。
    func assigning(_ chord: KeyChord, to command: Command) -> Result<KeyBindings, AssignError> {
        if Self.reservedChords.contains(chord) { return .failure(.reserved) }
        if command.isGlobal && !chord.isGlobalSafe { return .failure(.globalNeedsModifier) }
        if let owner = Command.allCases.first(where: { $0 != command && chords(for: $0).contains(chord) }) {
            return .failure(.conflict(owner))
        }
        return .success(setting([chord], for: command))
    }

    func clearing(_ command: Command) -> KeyBindings {
        setting([], for: command)
    }

    func resetting(_ command: Command) -> KeyBindings {
        var copy = self
        copy.overrides[command] = nil
        return copy
    }

    func resettingAll() -> KeyBindings {
        KeyBindings()
    }

    /// 既定と同じ内容になる場合は override を持たない（差分だけを保持する不変条件）。
    private func setting(_ chords: [KeyChord], for command: Command) -> KeyBindings {
        var copy = self
        copy.overrides[command] = chords == (Self.defaults[command] ?? []) ? nil : chords
        return copy
    }
}
