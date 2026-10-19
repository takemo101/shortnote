import AppKit

/// キャンバスの左下に重ねる、ビューの帯（SPEC §3.2.5）：いまの倍率（押すと 100% に戻る）と、戻すボタン（等倍・移動なしに戻る）。
/// ビューが、等倍・移動なしのときは、出さない（描く場所をふさがない）。画面だけの部品で、書き出しには入らない。
final class ViewControlsView: NSView {
    var onResetZoom: (() -> Void)?
    var onResetView: (() -> Void)?

    private(set) lazy var zoomButton: NSButton = {
        let button = NSButton(title: "100%", target: self, action: #selector(resetZoom))
        button.isBordered = false
        button.controlSize = .small
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = "拡大率を 100% に戻す"
        button.setAccessibilityIdentifier("zoomPercent")
        button.setAccessibilityHelp("押すと、拡大率が 100% に戻る")
        button.refusesFirstResponder = true
        return button
    }()

    private(set) lazy var resetButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "ビューを元に戻す") ?? NSImage(),
            target: self, action: #selector(resetView)
        )
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.controlSize = .small
        button.toolTip = "ビューの位置と拡大率を元に戻す"
        button.setAccessibilityLabel("ビューを元に戻す")
        button.setAccessibilityIdentifier("viewReset")
        button.refusesFirstResponder = true
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        let stack = NSStackView(views: [zoomButton, resetButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
        setAccessibilityElement(false)
    }

    /// 背景と縁の色は、見た目（ライト・ダーク）が変わったときにも、作り直す（`init` で、1 度だけ決めない）。
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 倍率の表示：整数の %（例：125%）。
    static func zoomText(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// 表示を、いまのビューに合わせる。等倍・移動なしなら、隠す。
    func show(_ viewport: Viewport) {
        let text = Self.zoomText(viewport.zoom)
        if zoomButton.title != text { zoomButton.title = text }
        isHidden = viewport.isIdentity
    }

    @objc private func resetZoom() { onResetZoom?() }
    @objc private func resetView() { onResetView?() }
}
