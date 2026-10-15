import Carbon.HIToolbox
import CoreGraphics

/// 現在のキーボード配列（US・JIS など）を調べる。
enum KeyboardLayout {
    /// この配列で、修飾キーなしの物理キー `keyCode` が出す文字。調べられない・文字を出さないキーは `nil`。
    /// 配列は ASCII を出せる現在のもの（日本語入力がオンでも、ローマ字入力のもとの配列）を使い、キーボードの種類（JIS など）も反映する。
    static func character(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), 0,
                UInt32(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
