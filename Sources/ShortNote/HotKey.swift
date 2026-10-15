import Carbon.HIToolbox

/// Carbon の RegisterEventHotKey による全域ショートカット。アクセシビリティ権限は不要。
final class HotKey {
    private static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?

    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.handler = handler

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                HotKey.handler?()
                return noErr
            },
            1, &spec, nil, nil
        )
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x534E_4F54), id: 1)  // 'SNOT'
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id,
            GetApplicationEventTarget(), 0, &ref
        )
        guard registered == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
