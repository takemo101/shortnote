import Foundation

/// 修飾キーの組み合わせ。ビット値は永続化されるので変更しないこと。
struct KeyModifiers: OptionSet, Hashable, Codable {
    let rawValue: UInt8
    static let control = KeyModifiers(rawValue: 1)
    static let option = KeyModifiers(rawValue: 2)
    static let shift = KeyModifiers(rawValue: 4)
    static let command = KeyModifiers(rawValue: 8)
}

/// 物理キー（macOS の仮想キーコード）＋修飾キー。
/// 同一性は keyCode と modifiers だけで決まり、label は表示専用。
struct KeyChord: Hashable, Codable {
    let keyCode: UInt16
    let modifiers: KeyModifiers
    let label: String

    init(keyCode: UInt16, modifiers: KeyModifiers = [], label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    static func == (lhs: KeyChord, rhs: KeyChord) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    /// macOS の表記順（⌃⌥⇧⌘）で修飾キーを並べ、続けてキー名を付ける。
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + label
    }

    private static let escapeKeyCode: UInt16 = 53
    /// F1〜F12 のキーコード。
    private static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    private var isBareFunctionKey: Bool {
        modifiers.isEmpty && Self.functionKeyCodes.contains(keyCode)
    }

    /// テキスト入力中でも処理してよいか。
    /// 素の文字キーや ⌥/⇧ だけの組み合わせは入力そのものなので不可。
    var isTypingSafe: Bool {
        !modifiers.isDisjoint(with: [.command, .control])
            || (modifiers.isEmpty && keyCode == Self.escapeKeyCode)
            || isBareFunctionKey
    }

    /// システム全域ホットキーにしてよいか。素の文字キーや ⇧ だけだと他アプリの入力を奪うため不可。
    var isGlobalSafe: Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option]) || isBareFunctionKey
    }
}
