import Foundation

/// コマンドとキーの割り当て。既定値との差分（overrides）だけを保持する。
struct KeyBindings: Equatable {
    private static func chord(_ code: UInt16, _ mods: KeyModifiers, _ label: String) -> KeyChord {
        KeyChord(keyCode: code, modifiers: mods, label: label)
    }

    private static func chord(_ code: UInt16, _ label: String) -> KeyChord {
        KeyChord(keyCode: code, label: label)
    }

    /// 既定の割り当て（US 配列の物理キー）。単体テストと、配列を調べられないときの基準。
    static let defaults: [Command: [KeyChord]] = standardDefaults(bracketKeyCodes: (smaller: 33, larger: 30))

    /// 現在のキーボード配列に合わせた既定。`[` `]` は、配列によって物理キーの位置が違う（JIS では別のキー）ので、
    /// `characterForKeyCode`（現在の配列で、修飾キーなしの物理キーが出す文字）から、その文字を出すキーを探す。
    /// 次のどれかのときは、US 配列の位置（`defaults`）にする：どちらかが見つからない、同じキーになる、
    /// 他の既定や予約済みのキーと重なる（`[` が数字の段にある配列など）。他のキー（数字・英字・Esc）は、配列が違っても同じ位置にある。
    static func standardDefaults(characterForKeyCode: (UInt16) -> String?) -> [Command: [KeyChord]] {
        func keyCode(of character: String) -> UInt16? {
            (UInt16(0)..<128).first { characterForKeyCode($0) == character }
        }
        guard let smaller = keyCode(of: "["), let larger = keyCode(of: "]") else { return defaults }
        let resolved = standardDefaults(bracketKeyCodes: (smaller: smaller, larger: larger))
        let all = resolved.values.flatMap { $0 }
        let consistent = Set(all).count == all.count && !all.contains { reservedChords.contains($0) }
        return consistent ? resolved : defaults
    }

    private static func standardDefaults(bracketKeyCodes: (smaller: UInt16, larger: UInt16)) -> [Command: [KeyChord]] {
        [
            .showPanel: [chord(45, [.control, .option], "N")],
            .hidePanel: [chord(53, "Esc")],
            .undo: [chord(6, .command, "Z"), chord(6, .control, "Z")],
            .redo: [chord(6, [.command, .shift], "Z"), chord(6, [.control, .shift], "Z")],
            .clearCanvas: [chord(40, .command, "K")],
            .pasteImage: [chord(9, .command, "V")],
            .openImage: [chord(31, .command, "O")],
            .copyPath: [chord(8, [.command, .shift], "C")],
            .toolPen: [chord(18, "1")],
            .toolEllipse: [chord(19, "2")],
            .toolRect: [chord(20, "3")],
            .toolText: [chord(21, "4")],
            .toolMove: [chord(23, "5")],
            .brushSmaller: [chord(bracketKeyCodes.smaller, "[")],
            .brushLarger: [chord(bracketKeyCodes.larger, "]")],
        ]
    }

    /// OS やテキスト編集の標準動作と衝突するため割り当て不可のキー。
    static let reservedChords: Set<KeyChord> = [
        chord(8, .command, "C"), chord(7, .command, "X"), chord(0, .command, "A"),
        chord(12, .command, "Q"), chord(4, .command, "H"), chord(46, .command, "M"),
        chord(13, .command, "W"), chord(43, .command, ","),
        chord(49, .command, "Space"), chord(48, .command, "Tab"),
    ]

    /// この配列での、各コマンドの既定の割り当て。
    let defaultChords: [Command: [KeyChord]]

    /// 既定との差分。空配列は「意図的に未割り当て」。
    private(set) var overrides: [Command: [KeyChord]]

    init(overrides: [Command: [KeyChord]] = [:], defaultChords: [Command: [KeyChord]] = KeyBindings.defaults) {
        self.overrides = overrides
        self.defaultChords = defaultChords
    }

    func chords(for command: Command) -> [KeyChord] {
        overrides[command] ?? defaultChords[command] ?? []
    }

    func isCustomized(_ command: Command) -> Bool {
        guard let override = overrides[command] else { return false }
        return override != (defaultChords[command] ?? [])
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

    /// `command` を初期値に戻す。初期値のキーを他のコマンドが使っているときは、`assigning` と同じく、
    /// 重ならないよう拒否する（先に相手を変えるか外す必要がある）。
    func resetting(_ command: Command) -> Result<KeyBindings, AssignError> {
        for chord in defaultChords[command] ?? [] {
            if let owner = Command.allCases.first(where: { $0 != command && chords(for: $0).contains(chord) }) {
                return .failure(.conflict(owner))
            }
        }
        var copy = self
        copy.overrides[command] = nil
        return .success(copy)
    }

    func resettingAll() -> KeyBindings {
        KeyBindings(defaultChords: defaultChords)
    }

    /// 既定と同じ内容になる場合は override を持たない（差分だけを保持する不変条件）。
    private func setting(_ chords: [KeyChord], for command: Command) -> KeyBindings {
        var copy = self
        copy.overrides[command] = chords == (defaultChords[command] ?? []) ? nil : chords
        return copy
    }
}
