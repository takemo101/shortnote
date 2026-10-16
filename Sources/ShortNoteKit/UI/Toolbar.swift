import AppKit

/// パネルの上段（ツール・画像追加・色・ブラシ・背景透過）と下段（ドラッグ・パスのコピー）。
/// 操作は、コールバックで通知するだけ。何をするかは `PaintWindowController` が決める。
final class Toolbar: NSObject {
    /// ブラシの太さの範囲。
    static let brushRange: ClosedRange<CGFloat> = 1...40

    var onSelectTool: ((Tool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onBrushSize: ((CGFloat) -> Void)?
    var onTextSize: ((CGFloat) -> Void)?
    var onTransparent: ((Bool) -> Void)?
    var onPickImages: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onClear: (() -> Void)?
    /// 円・四角の描き方（枠だけ／塗りつぶし）が選ばれた。選んだツールへの切り替えも、`onSelectTool` で別に知らせる。
    var onSelectFill: ((Tool, Bool) -> Void)?
    /// 直線の矢じり（線・矢印・両端の矢印）が選ばれた。直線のツールへの切り替えも、`onSelectTool` で別に知らせる。
    var onSelectArrow: ((Item.Arrow) -> Void)?
    /// 直線で選んでいる矢じり。ボタンの絵とメニューのチェックに使う。保存しない。
    private var lineArrow: Item.Arrow = .none
    /// 塗りつぶしを選んでいるツール（円・四角）。ボタンの絵とメニューのチェックに使う。保存しない。
    private var filledTools: Set<Tool> = []
    var fileProvider: (() -> URL?)? {
        get { handle.fileProvider }
        set { handle.fileProvider = newValue }
    }

    private(set) lazy var topRow: NSStackView = {
        let row = NSStackView(views: [tools, pickButton, colorWell, slider, textSizePopup, transparentCheckbox])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }()

    private(set) lazy var bottomRow: NSStackView = {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [handle, spacer, clearButton, copyButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }()

    private let handle = DragHandleView()
    private let copyButton = NSButton(title: Toolbar.copyTitle, target: nil, action: nil)
    private static let copyTitle = "パスをコピー"

    /// 描いたものを消す。背景画像は残る。取り消しで戻せるので、確認は出さない。
    private let clearButton: NSButton = {
        let button = NSButton(title: "クリア", target: nil, action: nil)
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.refusesFirstResponder = true
        return button
    }()

    private lazy var tools: NSSegmentedControl = {
        let symbols = ["pencil.tip", "line.diagonal", "circle", "square", "textformat", "arrow.up.and.down.and.arrow.left.and.right"]
        let control = NSSegmentedControl(
            images: symbols.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() },
            trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:))
        )
        control.selectedSegment = 0
        control.refusesFirstResponder = true
        // 円・四角のボタンに、「枠だけ／塗りつぶし」のメニュー（押し続けると開く。目印が出る）。普通に押すと、ツールの選択だけ。右クリックでは開かない（実験で確認）。
        for tool in Self.fillTools {
            control.setMenu(fillMenu(for: tool), forSegment: tool.rawValue)
            control.setShowsMenuIndicator(true, forSegment: tool.rawValue)
        }
        // 直線のボタンにも、「線／矢印／両端の矢印」のメニュー（同じ形）
        control.setMenu(arrowMenu(), forSegment: Tool.line.rawValue)
        control.setShowsMenuIndicator(true, forSegment: Tool.line.rawValue)
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
        slider.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return slider
    }()

    /// 文字を入れるときの大きさ（ブラシの太さとは別）。
    private lazy var textSizePopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: TextSize.presets.map { "\(Int($0)) pt" })
        popup.selectItem(at: TextSize.presets.firstIndex(of: TextSize.default) ?? 0)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        popup.target = self
        popup.action = #selector(textSizeChanged(_:))
        popup.refusesFirstResponder = true
        popup.setAccessibilityLabel("文字サイズ")
        popup.setAccessibilityIdentifier("text-size")
        popup.toolTip = "文字サイズ"
        return popup
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
        clearButton.target = self
        clearButton.action = #selector(clearCanvas)
    }

    /// 表示を、いまの状態に合わせる（キーボードで切り替えたときにも使う）。
    func show(tool: Tool) { tools.selectedSegment = tool.rawValue }

    // MARK: - 円・四角の塗りつぶし

    static let fillTools: [Tool] = [.ellipse, .rect]

    /// ボタンの絵：枠だけは `circle`・`square`、塗りつぶしは `circle.fill`・`square.fill`。
    private static func symbol(for tool: Tool, filled: Bool) -> String {
        switch (tool, filled) {
        case (.ellipse, false): return "circle"
        case (.ellipse, true): return "circle.fill"
        case (.rect, false): return "square"
        case (.rect, true): return "square.fill"
        default: return ""
        }
    }

    private func fillMenu(for tool: Tool) -> NSMenu {
        let menu = NSMenu(title: tool == .ellipse ? "円" : "四角")
        for (title, filled) in [("枠だけ", false), ("塗りつぶし", true)] {
            let item = NSMenuItem(title: title, action: #selector(fillChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tool.rawValue * 2 + (filled ? 1 : 0)
            item.image = NSImage(systemSymbolName: Self.symbol(for: tool, filled: filled), accessibilityDescription: title)
            item.state = filled == filledTools.contains(tool) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// メニューから選んだ。ボタンの絵とチェックを直し、そのツールに切り替える。
    @objc private func fillChosen(_ sender: NSMenuItem) {
        guard let tool = Tool(rawValue: sender.tag / 2), Self.fillTools.contains(tool) else { return }
        let filled = sender.tag % 2 == 1
        if filled { filledTools.insert(tool) } else { filledTools.remove(tool) }
        tools.setImage(NSImage(systemSymbolName: Self.symbol(for: tool, filled: filled), accessibilityDescription: nil), forSegment: tool.rawValue)
        if let menu = tools.menu(forSegment: tool.rawValue) {
            for item in menu.items { item.state = (item.tag % 2 == 1) == filled ? .on : .off }
        }
        tools.selectedSegment = tool.rawValue
        onSelectFill?(tool, filled)
        onSelectTool?(tool)
    }

    // MARK: - 直線の矢じり

    /// メニューの項目：題と、矢じり。
    private static let arrowChoices: [(title: String, arrow: Item.Arrow)] = [("線", .none), ("矢印", .end), ("両端の矢印", .both)]

    /// 絵。線は `line.diagonal`、矢印は `line.diagonal.arrow`（どちらも 14×13）。両端の矢印は、矢印の絵を 180° 回して重ねたもの（同じ 14×13。
    /// ボタンの幅が、どの選びでも変わらない。`arrow.up.left.and.arrow.down.right` は 16×15 で、ボタンが 2 pt 広がり、ツールバーの最小幅に、2 pt の余裕しかなかった）。
    static func arrowImage(_ arrow: Item.Arrow) -> NSImage? {
        guard let line = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: nil),
              let single = NSImage(systemSymbolName: "line.diagonal.arrow", accessibilityDescription: nil) else { return nil }
        switch arrow {
        case .none: return line
        case .end: return single
        case .both:
            let both = NSImage(size: single.size, flipped: false) { rect in
                single.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: .pi)
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
                single.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                return true
            }
            both.isTemplate = true   // 色は、ボタン・メニューの色に合わせる
            return both
        }
    }

    private func arrowMenu() -> NSMenu {
        let menu = NSMenu(title: "直線")
        for (index, choice) in Self.arrowChoices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(arrowChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Self.arrowImage(choice.arrow)
            item.state = choice.arrow == lineArrow ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// メニューから選んだ。ボタンの絵とチェックを直し、直線のツールに切り替える。
    @objc private func arrowChosen(_ sender: NSMenuItem) {
        guard Self.arrowChoices.indices.contains(sender.tag) else { return }
        lineArrow = Self.arrowChoices[sender.tag].arrow
        tools.setImage(Self.arrowImage(lineArrow), forSegment: Tool.line.rawValue)
        if let menu = tools.menu(forSegment: Tool.line.rawValue) {
            for item in menu.items { item.state = item.tag == sender.tag ? .on : .off }
        }
        tools.selectedSegment = Tool.line.rawValue
        onSelectArrow?(lineArrow)
        onSelectTool?(.line)
    }
    func show(brushSize: CGFloat) { slider.doubleValue = Double(brushSize) }
    func show(textSize: CGFloat) {
        if let index = TextSize.presets.firstIndex(of: textSize) { textSizePopup.selectItem(at: index) }
    }
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
        let toolCommands: [(String, Command)] = [("ペン", .toolPen), ("直線", .toolLine), ("円", .toolEllipse), ("四角", .toolRect), ("文字", .toolText), ("移動", .toolMove)]
        for (i, entry) in toolCommands.enumerated() {
            let base = hint(entry.0, entry.1)
            let extra = Self.fillTools.contains(where: { $0.rawValue == i }) ? "　押し続けると、枠だけ／塗りつぶしを選べる" : (i == Tool.line.rawValue ? "　押し続けると、線／矢印／両端の矢印を選べる" : "")
            tools.setToolTip(base + extra, forSegment: i)
        }
        pickButton.toolTip = hint("画像を追加…", .openImage)
        copyButton.toolTip = hint("書き出した画像のパスをコピー", .copyPath)
        clearButton.toolTip = hint("描いたものをすべて消す（背景画像は残る。取り消しで戻せる）", .clearCanvas)
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
    @objc private func textSizeChanged(_ sender: NSPopUpButton) {
        guard TextSize.presets.indices.contains(sender.indexOfSelectedItem) else { return }
        onTextSize?(TextSize.presets[sender.indexOfSelectedItem])
    }
    @objc private func transparentChanged(_ sender: NSButton) { onTransparent?(sender.state == .on) }
    @objc private func pickImages() { onPickImages?() }
    @objc private func copyPath() { onCopyPath?() }
    @objc private func clearCanvas() { onClear?() }
}
