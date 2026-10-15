import Carbon.HIToolbox

/// 全域ショートカット（Carbon の `RegisterEventHotKey`。アクセシビリティ権限は要らない）。
/// 登録できるのは 1 つ。`register` で、別のキーへ登録し直せる。
final class GlobalHotKey {
    private static var action: (() -> Void)?
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        Self.action = action
    }

    deinit {
        unregister()
    }

    /// `chord` で登録し直す。すでに他のアプリが使っているなど、登録できなければ `false`（そのとき、何も登録されない）。
    @discardableResult
    func register(_ chord: KeyChord) -> Bool {
        unregister()
        guard Self.installHandlerIfNeeded() else { return false }
        let id = EventHotKeyID(signature: OSType(0x534E_4F54), id: 1)  // 'SNOT'
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), chord.carbonModifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status != noErr { ref = nil }
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private static func installHandlerIfNeeded() -> Bool {
        if handlerInstalled { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                GlobalHotKey.action?()
                return noErr
            },
            1, &spec, nil, nil
        )
        handlerInstalled = status == noErr
        return handlerInstalled
    }
}

extension KeyChord {
    /// Carbon の修飾キーの値。
    var carbonModifiers: UInt32 {
        var mask = 0
        if modifiers.contains(.control) { mask |= controlKey }
        if modifiers.contains(.option) { mask |= optionKey }
        if modifiers.contains(.shift) { mask |= shiftKey }
        if modifiers.contains(.command) { mask |= cmdKey }
        return UInt32(mask)
    }
}
