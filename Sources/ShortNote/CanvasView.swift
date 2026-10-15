import AppKit
import UniformTypeIdentifiers

enum Tool: Int {
    case pen, ellipse, rect, text, move
}

enum Kind {
    case pen, ellipse, rect, text, image
}

struct StrokePoint {
    var point: CGPoint
    var pressure: CGFloat
}

struct Item {
    var kind: Kind
    var color: NSColor
    var size: CGFloat                 // 線の太さ / 文字サイズ
    var points: [StrokePoint] = []    // pen
    var rect: CGRect = .zero          // ellipse / rect / text / image
    var text = ""
    var image: NSImage?

    var bounds: CGRect {
        // 図形は線の太さの分だけ外側まで当たりにする（太い線の外側の半分も掴めるように）。
        if kind == .ellipse || kind == .rect { return rect.insetBy(dx: -size / 2, dy: -size / 2) }
        guard kind == .pen else { return rect }
        guard let first = points.first else { return .zero }
        var minX = first.point.x, maxX = minX, minY = first.point.y, maxY = minY
        for p in points {
            minX = min(minX, p.point.x); maxX = max(maxX, p.point.x)
            minY = min(minY, p.point.y); maxY = max(maxY, p.point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -size / 2, dy: -size / 2)
    }

    func translated(by d: CGSize) -> Item {
        var item = self
        item.rect = rect.offsetBy(dx: d.width, dy: d.height)
        item.points = points.map { StrokePoint(point: CGPoint(x: $0.point.x + d.width, y: $0.point.y + d.height), pressure: $0.pressure) }
        return item
    }
}

/// Undo/Redo の単位。画像の読み込み・貼り付け・ドロップ・ファイル選択・文字・移動もここに含まれるので取り消せる。
/// 背景画像の位置は読み込み時に確定し、ウィンドウの大きさを変えても動かさない（描いた内容とずれないように）。
struct Doc {
    var background: NSImage?
    var backgroundRect: CGRect = .zero
    var items: [Item] = []
}

/// 座標はすべて左上が原点（`isFlipped`）。ウィンドウを広げても、描いた内容は左上から動かない。
final class CanvasView: NSView {
    /// キャンバスの最小の大きさ（ポイント）。ウィンドウはこれより小さくできない。
    static let minimumSize = NSSize(width: 480, height: 320)
    /// 書き出す PNG の長辺の上限（ピクセル）。最大化した大きなキャンバスで巨大になりすぎないように。
    static let maxExportSide: CGFloat = 8192
    /// 取り消せる段数の上限。
    static let maxUndoSteps = 200

    var tool: Tool = .pen {
        didSet {
            commitEditing()
            window?.invalidateCursorRects(for: self)
        }
    }
    var color: NSColor = .black
    var brushSize: CGFloat = 4
    var transparent = false {
        didSet {
            needsDisplay = true
            onChange?()
        }
    }
    /// 書き出し結果が変わる操作のたびに呼ばれる。
    var onChange: (() -> Void)?

    private var doc = Doc()
    private var undoStack: [Doc] = []
    private var redoStack: [Doc] = []
    private var draft: Item?
    private var dragStart: CGPoint = .zero

    // 移動ツール
    private var moveIndex: Int?
    private var moveBase: Doc?

    // 文字入力
    private var editor: NSTextView?
    private var editorAnchor: CGPoint = .zero   // 文字ボックスの左上
    private var editorFontSize: CGFloat = 18
    private var editorColor: NSColor = .black
    var isEditing: Bool { editor != nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("キャンバス")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        // 入力中にパネルからフォーカスが外れたら確定する。
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowLostKey), name: NSWindow.didResignKeyNotification, object: window
        )
    }

    @objc private func windowLostKey() { commitEditing() }

    /// キャンバスの大きさが変わると、書き出し PNG の寸法も変わる。書き出しの再利用を無効にする。
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { onChange?() }
    }

    override func resetCursorRects() {
        switch tool {
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .move: addCursorRect(bounds, cursor: .openHand)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - History

    func undo() {
        commitEditing()
        cancelPointerInteraction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = previous
        changed()
    }

    func redo() {
        commitEditing()
        cancelPointerInteraction()
        guard let next = redoStack.popLast() else { return }
        pushUndo(doc)
        doc = next
        changed()
    }

    private func commit(_ new: Doc) {
        cancelPointerInteraction()
        pushUndo(doc)
        redoStack.removeAll()
        doc = new
        changed()
    }

    /// 履歴に積む。上限を超えたら、いちばん古いものから捨てる（長い作業でメモリが増え続けないように）。
    private func pushUndo(_ d: Doc) {
        undoStack.append(d)
        if undoStack.count > Self.maxUndoSteps { undoStack.removeFirst(undoStack.count - Self.maxUndoSteps) }
    }

    /// ポインタ操作の途中（描いている線・移動中の要素）を捨てる。ボタンを押したまま取り消し・貼り付けをされても、古い状態を書き戻さないように。
    /// 移動の途中なら、移動前の状態へ戻す（取り消し・やり直し・追加が、半端な位置を履歴に残さない）。
    private func cancelPointerInteraction() {
        if let base = moveBase {
            doc = base
            needsDisplay = true
        }
        draft = nil
        moveIndex = nil
        moveBase = nil
    }

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    /// 画像を背景として開く（CLI 引数 / `open`）。新しいキャンバスになる（直前の状態は Undo で戻せる）。
    @discardableResult
    func loadImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url), image.isValid else { return false }
        commitEditing()
        commit(Doc(background: image, backgroundRect: fittedRect(for: image), items: []))
        return true
    }

    // MARK: - Images (paste / drop / file picker)

    /// ファイルの種類（型）が画像なら画像。型が不明・汎用（拡張子が無い・合わないファイルは `public.data` などになる）のときは、
    /// 後段の `images(at:)` が実際に画像として読めるかで判断する。画像以外の型（テキストなど）は受け付けない。
    private static func isImageFile(_ url: URL) -> Bool {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            return type.conforms(to: .image) || type == .data || type.isDynamic
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// 画像ファイルだけを読む（読めないもの・画像でないものは捨てる）。
    static func images(at urls: [URL]) -> [NSImage] {
        urls.compactMap { url in
            guard isImageFile(url), let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
            return image
        }
    }

    /// ファイルURL（画像のみ）を優先し、なければ画像データそのもの。
    /// ファイルURLがあるのに画像でなければ、アイコン画像を拾わないよう nil。
    static func images(from pb: NSPasteboard) -> [NSImage] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return images(at: urls) }
        let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
        return images.filter { $0.isValid && $0.size.width > 0 && $0.size.height > 0 }
    }

    static func canAcceptImage(_ pb: NSPasteboard) -> Bool {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.contains { isImageFile($0) } }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// キャンバスの 70% に収まるよう縮小し（拡大はしない）、`center` を中心に置く。
    private func imageItem(_ image: NSImage, center: CGPoint) -> Item {
        let s = min(bounds.width * 0.7 / image.size.width, bounds.height * 0.7 / image.size.height, 1)
        let w = image.size.width * s, h = image.size.height * s
        return Item(kind: .image, color: .black, size: 0,
                    rect: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), image: image)
    }

    /// Cmd+V。クリップボードの画像を中央に置く。
    @discardableResult
    func pasteImages() -> Bool {
        commitEditing()
        return place(Self.images(from: .general), at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// ファイル選択で選ばれた画像を中央に置く。
    @discardableResult
    func addImages(at urls: [URL]) -> Bool {
        commitEditing()
        return place(Self.images(at: urls), at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func place(_ images: [NSImage], at center: CGPoint) -> Bool {
        guard !images.isEmpty else { NSSound.beep(); return false }
        cancelPointerInteraction()   // 移動の途中なら、移動前に戻してから足す（履歴に半端な位置を残さない）
        var new = doc
        for (i, image) in images.enumerated() {
            // 複数枚は少しずらして重ね、全部見えるようにする。
            new.items.append(imageItem(image, center: CGPoint(x: center.x + CGFloat(i) * 16, y: center.y + CGFloat(i) * 16)))
        }
        commit(new)
        return true
    }

    // MARK: - Mouse / tablet

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// 筆圧はタブレット入力のときだけ使う。トラックパッドの感圧では太さを変えない。
    private func pressure(_ event: NSEvent) -> CGFloat {
        event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1
    }

    override func mouseDown(with event: NSEvent) {
        commitEditing()
        let p = location(event)
        dragStart = p
        switch tool {
        case .pen:
            draft = Item(
                kind: .pen, color: color, size: brushSize,
                points: [StrokePoint(point: p, pressure: pressure(event))]
            )
        case .ellipse:
            draft = Item(kind: .ellipse, color: color, size: brushSize, rect: CGRect(origin: p, size: .zero))
        case .rect:
            draft = Item(kind: .rect, color: color, size: brushSize, rect: CGRect(origin: p, size: .zero))
        case .text:
            beginEditing(at: p)
        case .move:
            if let i = doc.items.lastIndex(where: { $0.bounds.insetBy(dx: -4, dy: -4).contains(p) }) {
                moveIndex = i
                moveBase = doc
                NSCursor.closedHand.set()
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(event)
        if let i = moveIndex, let base = moveBase {
            guard i < doc.items.count else { return }   // 履歴の操作などで要素が減っていたら、動かさない
            doc.items[i] = base.items[i].translated(by: CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y))
            needsDisplay = true
            return
        }
        guard var item = draft else { return }
        switch item.kind {
        case .pen:
            item.points.append(StrokePoint(point: p, pressure: pressure(event)))
        default:
            item.rect = CGRect(
                x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y)
            )
        }
        draft = item
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moveIndex != nil, let base = moveBase {
            moveIndex = nil
            moveBase = nil
            window?.invalidateCursorRects(for: self)
            if location(event) != dragStart {
                pushUndo(base)
                redoStack.removeAll()
                changed()
            }
            return
        }
        guard let item = draft else { return }
        draft = nil
        if item.kind != .pen, item.rect.width < 1 || item.rect.height < 1 {
            needsDisplay = true  // 大きさのない図形は捨てる
            return
        }
        var new = doc
        new.items.append(item)
        commit(new)
    }

    // MARK: - Text

    static func attributed(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ])
    }

    private func beginEditing(at p: CGPoint) {
        editorFontSize = 12 + brushSize * 1.5
        editorColor = color
        editorAnchor = p

        let lineH = ceil(editorFontSize * 1.3)
        let tv = NSTextView(frame: NSRect(x: p.x, y: p.y, width: 40, height: lineH))
        tv.delegate = self
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: editorFontSize, weight: .medium)
        tv.textColor = color
        tv.insertionPointColor = color
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1e5, height: 1e5)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        addSubview(tv)
        editor = tv
        window?.makeFirstResponder(tv)
    }

    private func resizeEditor() {
        guard let tv = editor, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let w = min(max(used.width + 8, 40), max(40, bounds.width - editorAnchor.x))
        let h = max(ceil(used.height), ceil(editorFontSize * 1.3))
        tv.frame = NSRect(x: editorAnchor.x, y: editorAnchor.y, width: w, height: h)
    }

    /// 入力中の文字を確定する。空なら捨てる。
    func commitEditing() {
        guard let tv = editor else { return }
        let text = tv.string
        editor = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let size = Self.attributed(text, size: editorFontSize, color: editorColor)
            .boundingRect(with: NSSize(width: 1e5, height: 1e5), options: [.usesLineFragmentOrigin]).size
        let w = ceil(size.width), h = ceil(size.height)
        var new = doc
        new.items.append(Item(
            kind: .text, color: editorColor, size: editorFontSize,
            rect: CGRect(x: editorAnchor.x, y: editorAnchor.y, width: w, height: h), text: text
        ))
        commit(new)
    }

    func cancelEditing() {
        guard let tv = editor else { return }
        editor = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    // MARK: - Drop (image in)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.canAcceptImage(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.canAcceptImage(sender.draggingPasteboard) ? .copy : []
    }

    /// ドロップした位置を中心に画像を追加する。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        commitEditing()
        let images = Self.images(from: sender.draggingPasteboard)
        return place(images, at: convert(sender.draggingLocation, from: nil))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if transparent {
            drawChecker(in: ctx)
        } else {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(bounds)
        }
        drawContent(in: ctx)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawChecker(in ctx: CGContext) {
        let tile: CGFloat = 8
        ctx.setFillColor(NSColor(white: 1, alpha: 1).cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
        var y: CGFloat = 0
        var row = 0
        while y < bounds.height {
            var x: CGFloat = row % 2 == 0 ? 0 : tile
            while x < bounds.width {
                ctx.fill(CGRect(x: x, y: y, width: tile, height: tile))
                x += tile * 2
            }
            y += tile
            row += 1
        }
    }

    /// 背景画像 → 確定済みの要素 → 描画中の要素。
    private func drawContent(in ctx: CGContext) {
        if let image = doc.background {
            image.draw(in: doc.backgroundRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for item in doc.items { draw(item, in: ctx) }
        if let draft { draw(draft, in: ctx) }
    }

    /// 現在のキャンバスに収まるようアスペクト比を保って中央配置する。拡大はしない。
    private func fittedRect(for image: NSImage) -> CGRect {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return bounds }
        let scale = min(bounds.width / s.width, bounds.height / s.height, 1)
        let w = s.width * scale
        let h = s.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func lineWidth(_ size: CGFloat, pressure: CGFloat) -> CGFloat {
        size * (0.25 + 0.75 * min(max(pressure, 0), 1))
    }

    private func draw(_ item: Item, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.kind {
        case .pen:
            let pts = item.points
            if pts.count == 1 {
                let w = lineWidth(item.size, pressure: pts[0].pressure)
                ctx.fillEllipse(in: CGRect(x: pts[0].point.x - w / 2, y: pts[0].point.y - w / 2, width: w, height: w))
            } else if pts.count > 1 {
                for i in 1..<pts.count {
                    ctx.setLineWidth(lineWidth(item.size, pressure: (pts[i - 1].pressure + pts[i].pressure) / 2))
                    ctx.move(to: pts[i - 1].point)
                    ctx.addLine(to: pts[i].point)
                    ctx.strokePath()
                }
            }
        case .rect:
            ctx.setLineWidth(item.size)
            ctx.stroke(item.rect)
        case .ellipse:
            ctx.setLineWidth(item.size)
            ctx.strokeEllipse(in: item.rect)
        case .text:
            Self.attributed(item.text, size: item.size, color: item.color)
                .draw(with: item.rect, options: [.usesLineFragmentOrigin])
        case .image:
            item.image?.draw(in: item.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: - Export

    /// 書き出しの倍率。ピクセル数 = キャンバスのポイント数 × 2（Retina 相当）に固定し、出力サイズを予測できるようにする。
    static let exportScale: CGFloat = 2

    /// 現在のキャンバス全体を PNG にする。背景透過オンなら白地を敷かず、アルファ付きにする。
    /// ピクセル数はキャンバスの 2 倍。長辺が `maxExportSide` を超える巨大なキャンバスでだけ、倍率を下げる。
    func renderPNG() -> Data? {
        commitEditing()
        var scale = Self.exportScale
        let longest = max(bounds.width, bounds.height)
        if longest > 0 { scale = min(scale, Self.maxExportSide / longest) }

        let size = bounds.size
        guard size.width > 0, size.height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        // ビットマップはピクセル座標で左下原点。画面と同じ「ポイント座標・左上原点」で描けるよう、
        // 上下を反転して倍率を掛け、反転済みのコンテキストとして渡す。
        let ctx = base.cgContext
        ctx.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        ctx.scaleBy(x: CGFloat(rep.pixelsWide) / size.width, y: -CGFloat(rep.pixelsHigh) / size.height)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }

        if !transparent {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        drawContent(in: ctx)
        return rep.representation(using: .png, properties: [:])
    }
}

extension CanvasView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { resizeEditor() }

    /// Return で確定、Shift/Option+Return で改行。IME 変換中の Return は変換の確定に使われここには来ない。
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
        } else {
            commitEditing()
        }
        return true
    }
}
