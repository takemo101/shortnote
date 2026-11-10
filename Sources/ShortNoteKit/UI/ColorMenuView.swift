import AppKit

/// 色のマス 1 つ（丸）。いまの色には、アクセントの輪が付く（`isCurrent`）。押し方は、`ShapeCellButton` と同じ。
final class ColorCellButton: ShapeCellButton {
    let color: NSColor
    var isCurrent = false { didSet { needsDisplay = true } }

    init(color: NSColor, label: String, size: NSSize) {
        self.color = color
        super.init(symbol: nil, label: label, role: .button, size: size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let disc = bounds.insetBy(dx: 6, dy: 6)
        color.setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()   // 白や黒に近い色でも、縁が見える
        let edge = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
        if isCurrent {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: disc.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

/// 色の見本のメニューの中身（SPEC §3.2）：代表的な 12 色の、丸のマス目（6 列 × 2 行）と、その下の「その他…」（色のパネルを開く）。
/// いまの色のマスには、輪が付く。マスを押すと、メニューを閉じて、`onChoose` で知らせる。
final class ColorMenuView: NSView {
    /// 代表的な色（名前と、sRGB の 16 進）。並びは、無彩色（黒・白・灰）のあと、色相の順。
    static let presets: [(name: String, hex: String)] = [
        ("黒", "000000"), ("白", "FFFFFF"), ("灰", "8E8E93"), ("赤", "E53935"), ("橙", "FB8C00"), ("黄", "FDD835"),
        ("緑", "43A047"), ("水色", "00ACC1"), ("青", "1E88E5"), ("紫", "8E24AA"), ("ピンク", "EC407A"), ("茶", "6D4C41"),
    ]

    /// 16 進（RRGGBB）の sRGB の色。
    static func color(hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// 同じ色か（sRGB の 8 ビットに丸めて比べる。透明度は見ない）。
    static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        func bytes(_ color: NSColor) -> [Int]? {
            guard let c = color.usingColorSpace(.sRGB) else { return nil }
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        guard let x = bytes(a), let y = bytes(b) else { return false }
        return x == y
    }

    var onChoose: ((NSColor) -> Void)?
    var onOther: (() -> Void)?

    private var cells: [ColorCellButton] = []
    private let otherButton: ShapeCellButton

    static let columns = 6
    private static let cellSize = NSSize(width: 32, height: 32)
    private static let inset: CGFloat = 8
    private static let otherHeight: CGFloat = 28

    init() {
        let rows = (Self.presets.count + Self.columns - 1) / Self.columns
        let gridWidth = CGFloat(Self.columns) * Self.cellSize.width
        let gridHeight = CGFloat(rows) * Self.cellSize.height
        let size = NSSize(width: gridWidth + 2 * Self.inset, height: gridHeight + Self.otherHeight + 3 * Self.inset)
        otherButton = ShapeCellButton(symbol: nil, label: "その他の色…", role: .button, showsTitle: true, size: NSSize(width: gridWidth, height: Self.otherHeight))
        super.init(frame: NSRect(origin: .zero, size: size))
        for (index, preset) in Self.presets.enumerated() {
            let row = index / Self.columns, column = index % Self.columns
            let cell = ColorCellButton(color: Self.color(hex: preset.hex), label: preset.name, size: Self.cellSize)
            cell.frame = NSRect(
                x: Self.inset + CGFloat(column) * Self.cellSize.width,
                y: size.height - Self.inset - CGFloat(row + 1) * Self.cellSize.height,
                width: Self.cellSize.width, height: Self.cellSize.height
            )
            cell.target = self
            cell.action = #selector(chosen(_:))
            cell.setAccessibilityIdentifier("color-\(preset.hex)")
            addSubview(cell)
            cells.append(cell)
        }
        otherButton.frame = NSRect(x: Self.inset, y: Self.inset, width: gridWidth, height: Self.otherHeight)
        otherButton.target = self
        otherButton.action = #selector(other)
        otherButton.setAccessibilityIdentifier("color-other")
        addSubview(otherButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// いまの色に、輪（押された形）を合わせる。代表色のどれでもない色のときは、どれにも付けない。
    func show(color: NSColor) {
        for cell in cells { cell.clearHover() }
        otherButton.clearHover()
        for cell in cells { cell.isCurrent = Self.sameColor(cell.color, color) }
    }

    @objc private func chosen(_ sender: ColorCellButton) {
        enclosingMenuItem?.menu?.cancelTracking()
        onChoose?(sender.color)
    }

    @objc private func other() {
        enclosingMenuItem?.menu?.cancelTracking()
        onOther?()
    }
}
