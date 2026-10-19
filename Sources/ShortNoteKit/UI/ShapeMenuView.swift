import AppKit

/// メニューのマス 1 つ。ボタンを押したまま（セグメント側で mouseDown）メニューを開き、そのままマスの上で離したときは、
/// マスには mouseUp だけが届く。この場合も、押したことにする（普通のメニュー項目と同じ操作ができるように）。
final class ShapeCellButton: NSButton {
    private var sawMouseDown = false

    override func mouseDown(with event: NSEvent) {
        sawMouseDown = true
        super.mouseDown(with: event)   // 離すまで、ここで追跡する（離したときの mouseUp は、ここで消費される）
        sawMouseDown = false
    }

    override func mouseUp(with event: NSEvent) {
        if !sawMouseDown, isEnabled { sendAction(action, to: target) }
        super.mouseUp(with: event)
    }
}

/// 「図形」のボタンのメニューの中身：2 列 × 3 行の、絵のマス目（SPEC §3.2.2）。左の列が「枠だけ」、右の列が「塗りつぶし」、
/// 上から 四角・円・三角。いま選んでいるマスは、押された形で示す。マスを押すと、メニューを閉じて、`onChoose` で知らせる。
final class ShapeMenuView: NSView {
    /// 上から並べる図形。
    static let shapes: [Tool] = [.rect, .ellipse, .triangle]

    /// ボタン・メニューの絵（SF Symbols）。枠だけ／塗りつぶし。
    static func symbol(for tool: Tool, filled: Bool) -> String {
        switch tool {
        case .ellipse: return filled ? "circle.fill" : "circle"
        case .rect: return filled ? "square.fill" : "square"
        case .triangle: return filled ? "triangle.fill" : "triangle"
        default: return ""
        }
    }

    /// ツールバーのボタンの絵。円・四角・三角の SF Symbols は、大きさがまちまち（15×15、15×14、17×15）なので、17×15 の中央に置く
    /// （どの選びでも、ボタンの幅が変わらず、右の部品が動かない）。
    static func buttonImage(for tool: Tool, filled: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: symbol(for: tool, filled: filled), accessibilityDescription: nil) else { return nil }
        let image = NSImage(size: NSSize(width: 17, height: 15), flipped: false) { rect in
            let s = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        image.isTemplate = true   // 色は、ボタンの色に合わせる
        return image
    }

    static func title(for tool: Tool) -> String {
        switch tool {
        case .ellipse: return "円"
        case .rect: return "四角"
        case .triangle: return "三角"
        default: return ""
        }
    }

    /// アクセシビリティの識別子（`shape-<ellipse|rect|triangle>-<outline|fill>`）。
    static func identifier(for tool: Tool, filled: Bool) -> String {
        let name: String
        switch tool {
        case .ellipse: name = "ellipse"
        case .rect: name = "rect"
        case .triangle: name = "triangle"
        default: name = "none"
        }
        return "shape-\(name)-\(filled ? "fill" : "outline")"
    }

    var onChoose: ((Tool, Bool) -> Void)?

    private var cells: [(tool: Tool, filled: Bool, button: NSButton)] = []

    private static let cellSize = NSSize(width: 44, height: 34)
    private static let inset: CGFloat = 6

    init() {
        let cols = 2, rows = Self.shapes.count
        let size = NSSize(width: CGFloat(cols) * Self.cellSize.width + 2 * Self.inset,
                          height: CGFloat(rows) * Self.cellSize.height + 2 * Self.inset)
        super.init(frame: NSRect(origin: .zero, size: size))
        for (row, tool) in Self.shapes.enumerated() {
            for (column, filled) in [false, true].enumerated() {
                let button = ShapeCellButton(frame: NSRect(
                    x: Self.inset + CGFloat(column) * Self.cellSize.width,
                    y: size.height - Self.inset - CGFloat(row + 1) * Self.cellSize.height,
                    width: Self.cellSize.width, height: Self.cellSize.height
                ))
                let title = "\(Self.title(for: tool))（\(filled ? "塗りつぶし" : "枠だけ")）"
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                button.image = NSImage(systemSymbolName: Self.symbol(for: tool, filled: filled), accessibilityDescription: title)?
                    .withSymbolConfiguration(symbolConfig)
                button.imagePosition = .imageOnly
                button.setButtonType(.pushOnPushOff)
                button.bezelStyle = .smallSquare
                button.isBordered = true
                button.target = self
                button.action = #selector(chosen(_:))
                button.refusesFirstResponder = true
                button.toolTip = title
                button.setAccessibilityLabel(title)
                button.setAccessibilityIdentifier(Self.identifier(for: tool, filled: filled))
                addSubview(button)
                cells.append((tool, filled, button))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// いまの選びに、印（押された形）を合わせる。
    func show(tool: Tool, filled: Bool) {
        for cell in cells { cell.button.state = (cell.tool == tool && cell.filled == filled) ? .on : .off }
    }

    @objc private func chosen(_ sender: NSButton) {
        guard let cell = cells.first(where: { $0.button === sender }) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onChoose?(cell.tool, cell.filled)
    }
}
