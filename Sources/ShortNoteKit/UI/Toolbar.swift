import AppKit

/// パネルの上段（ツール・画像追加・色・ブラシ・背景透過）と下段（ドラッグ・パスのコピー）。
/// 操作は、コールバックで通知するだけ。何をするかは `PaintWindowController` が決める。
final class Toolbar: NSObject {
    /// ブラシの太さの範囲。
    static let brushRange: ClosedRange<CGFloat> = 1...40

    var onSelectTool: ((Tool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onBrushSize: ((CGFloat) -> Void)?
    var onTransparent: ((Bool) -> Void)?
    var onPickImages: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var fileProvider: (() -> URL?)? {
        get { handle.fileProvider }
        set { handle.fileProvider = newValue }
    }

    private(set) lazy var topRow: NSStackView = {
        let row = NSStackView(views: [tools, pickButton, colorWell, slider, transparentCheckbox])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }()

    private(set) lazy var bottomRow: NSStackView = {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [handle, spacer, copyButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }()

    private let handle = DragHandleView()
    private let copyButton = NSButton(title: Toolbar.copyTitle, target: nil, action: nil)
    private static let copyTitle = "パスをコピー"

    private lazy var tools: NSSegmentedControl = {
        let symbols = ["pencil.tip", "circle", "square", "textformat", "arrow.up.and.down.and.arrow.left.and.right"]
        let control = NSSegmentedControl(
            images: symbols.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() },
            trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:))
        )
        control.selectedSegment = 0
        control.refusesFirstResponder = true
        return control
    }()

    private lazy var colorWell: NSColorWell = {
        let well = NSColorWell(style: .minimal)
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.refusesFirstResponder = true
        well.widthAnchor.constraint(equalToConstant: 36).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return well
    }()

    private lazy var slider: NSSlider = {
        let slider = NSSlider(value: 4, minValue: Double(Self.brushRange.lowerBound), maxValue: Double(Self.brushRange.upperBound), target: self, action: #selector(sizeChanged(_:)))
        slider.refusesFirstResponder = true
        slider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return slider
    }()

    private lazy var transparentCheckbox: NSButton = {
        let box = NSButton(checkboxWithTitle: "背景透過", target: self, action: #selector(transparentChanged(_:)))
        box.refusesFirstResponder = true
        return box
    }()

    private lazy var pickButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "画像を追加") ?? NSImage(),
            target: self, action: #selector(pickImages)
        )
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("画像を追加")
        button.refusesFirstResponder = true
        return button
    }()

    override init() {
        super.init()
        copyButton.target = self
        copyButton.action = #selector(copyPath)
        copyButton.bezelStyle = .rounded
        copyButton.refusesFirstResponder = true
    }

    /// 表示を、いまの状態に合わせる（キーボードで切り替えたときにも使う）。
    func show(tool: Tool) { tools.selectedSegment = tool.rawValue }
    func show(brushSize: CGFloat) { slider.doubleValue = Double(brushSize) }
    var color: NSColor {
        get { colorWell.color }
        set { colorWell.color = newValue }
    }

    /// ツールチップに、いまの割り当てを出す。
    func showHints(_ center: ShortcutCenter) {
        func hint(_ title: String, _ command: Command) -> String {
            let keys = center.chords(for: command).map(\.displayString).joined(separator: " / ")
            return keys.isEmpty ? title : "\(title)（\(keys)）"
        }
        let toolCommands: [(String, Command)] = [("ペン", .toolPen), ("円", .toolEllipse), ("四角", .toolRect), ("文字", .toolText), ("移動", .toolMove)]
        for (i, entry) in toolCommands.enumerated() { tools.setToolTip(hint(entry.0, entry.1), forSegment: i) }
        pickButton.toolTip = hint("画像を追加…", .openImage)
        copyButton.toolTip = hint("書き出した画像のパスをコピー", .copyPath)
        let smaller = center.chords(for: .brushSmaller).first?.displayString
        let larger = center.chords(for: .brushLarger).first?.displayString
        slider.toolTip = (smaller != nil && larger != nil) ? "ブラシサイズ（\(smaller!) 小さく / \(larger!) 大きく）" : "ブラシサイズ"
    }

    /// 「コピーしました」を一瞬だけ見せる。
    func flashCopied() {
        copyButton.title = "コピーしました"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = Self.copyTitle
        }
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) { onSelectTool?(Tool(rawValue: sender.selectedSegment) ?? .pen) }
    @objc private func colorChanged(_ sender: NSColorWell) { onColor?(sender.color) }
    @objc private func sizeChanged(_ sender: NSSlider) { onBrushSize?(CGFloat(sender.doubleValue)) }
    @objc private func transparentChanged(_ sender: NSButton) { onTransparent?(sender.state == .on) }
    @objc private func pickImages() { onPickImages?() }
    @objc private func copyPath() { onCopyPath?() }
}
