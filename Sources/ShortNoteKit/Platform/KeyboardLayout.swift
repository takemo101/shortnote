import Carbon.HIToolbox
import CoreGraphics

/// 現在のキーボード配列（US・JIS など）を調べる。
enum KeyboardLayout {
    /// この配列で、修飾キーなしの物理キー（キーコード 0〜127）が出す文字の対応表。文字を出さないキーは入らない。
    /// 配列は ASCII を出せる現在のもの（日本語入力がオンでも、ローマ字入力のもとの配列）を使い、キーボードの種類（JIS など）も反映する。
    /// 配列を調べられないときは空（呼び出し側が US の位置に戻す）。配列は 1 度だけ引き、全キーをその場で調べる。
    /// TIS はメインスレッドで使う。
    static func characters() -> [UInt16: String] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        let keyboardType = UInt32(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0)

        // `source` と `layoutData` を、`UCKeyTranslate` が読み終わるまで生かしておく。
        return withExtendedLifetime((source, layoutData)) {
            guard let bytes = CFDataGetBytePtr(layoutData) else { return [:] }
            var table: [UInt16: String] = [:]
            for keyCode in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                    UCKeyTranslate(
                        layout, keyCode, UInt16(kUCKeyActionDown), 0, keyboardType,
                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                        characters.count, &length, &characters
                    )
                }
                if status == noErr, length > 0 { table[keyCode] = String(utf16CodeUnits: characters, count: length) }
            }
            return table
        }
    }
}
