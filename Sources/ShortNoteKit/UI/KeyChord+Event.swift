import AppKit

extension KeyChord {
    /// キーが押されたイベントから、キーの組み合わせにする（境界で一度だけ型にする）。キー押下以外は `nil`。
    /// 物理のキーコードで判断するので、キーボードの配列（日本語・英語）に依らない。
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(keyCode: event.keyCode, modifiers: modifiers, label: Self.label(for: event))
    }

    /// 表示用のキー名。特殊なキーは名前で、文字のキーは大文字で表す。
    private static func label(for event: NSEvent) -> String {
        if let special = specialLabels[event.keyCode] { return special }
        let characters = event.charactersIgnoringModifiers ?? ""
        return characters.isEmpty ? "キー\(event.keyCode)" : characters.uppercased()
    }

    private static let specialLabels: [UInt16: String] = [
        53: "Esc", 36: "↩", 76: "⌅", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
