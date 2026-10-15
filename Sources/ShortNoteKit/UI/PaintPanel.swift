import AppKit

/// ShortNote のパネル。メニューバーを持たないアプリなので、フォーカス位置に関わらずショートカットを効かせるため、
/// キー入力を `sendEvent` で先に受け取る。何をするかは `keyHandler`（`PaintWindowController`）が決める。
final class PaintPanel: NSPanel {
    /// キー押下を扱ったら `true`（扱わなければ、通常のキー処理へ進む）。
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
