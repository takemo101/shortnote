import AppKit

/// ここからドラッグすると PNG のファイルパスがエージェントの入力欄に渡る。パレットの中の、枠のないボタンの見た目（ポインタが乗ると、淡い面）。
final class DragHandleView: NSView, NSDraggingSource {
    /// ドラッグ開始時に最新の PNG を書き出して URL を返す。
    var fileProvider: (() -> URL?)?
    private var dragStarted = false
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: 124, height: 30) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "ここから、エージェントの入力欄などへドラッグすると、書き出した画像のパスが渡る"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("ドラッグで渡す")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }   // 自分の領域だけ（ツールチップの領域〔`NSToolTipManager`〕を消さない）
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let label = NSAttributedString(
            string: "ドラッグで渡す",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82),
            ]
        )
        let icon = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [NSColor.labelColor.withAlphaComponent(0.82)])))
        let iconW: CGFloat = icon?.size.width ?? 0
        let gap: CGFloat = icon == nil ? 0 : 6
        let total = iconW + gap + label.size().width
        var x = (bounds.width - total) / 2
        if let icon {
            icon.draw(at: NSPoint(x: x, y: (bounds.height - icon.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            x += iconW + gap
        }
        label.draw(at: NSPoint(x: x, y: (bounds.height - label.size().height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let url = fileProvider?() else { return }
        dragStarted = true

        // ファイルURLと文字列(パス)の両方を載せる。ターミナル系はどちらでもパスとして貼り付く。
        let pb = NSPasteboardItem()
        pb.setString(url.absoluteString, forType: .fileURL)
        pb.setString(url.path, forType: .string)

        let item = NSDraggingItem(pasteboardWriter: pb)
        let thumb = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        let h: CGFloat = 64
        let w = thumb.size.height > 0 ? h * thumb.size.width / thumb.size.height : h
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), contents: thumb)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
