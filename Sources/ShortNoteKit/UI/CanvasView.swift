import AppKit

/// 描画ツール。`rawValue` は、ツールバーのセグメントの番号。
enum Tool: Int, CaseIterable {
    case pen, ellipse, rect, text, move
}

/// キャンバス。ポインタ入力を、`Document` の変更（履歴つき）につなぐ。描画は `CanvasRenderer`、文字入力は `InlineTextEditor` が行う。
/// 座標は左上原点（`isFlipped`）。ウィンドウを広げても、描いた内容は左上から動かない。
final class CanvasView: NSView {
    /// キャンバスの最小の大きさ（ポイント）。ウィンドウはこれより小さくできない。
    static let minimumSize = CanvasSize.minimum.points

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

    /// 書き出し結果が変わる操作（キャンバスの大きさの変更を含む）のたびに呼ぶ。
    var onChange: (() -> Void)?
    /// 画像を取り込めなかったとき。何を見せる（ビープなど）かは、呼び出し側が決める。
    var onIntakeFailure: ((ImageIntakeError) -> Void)?

    private var document = Document()
    private var history = History<Document>()
    private var draft: Item?
    private var dragStart = CGPoint.zero
    /// 移動ツールで、動かしている要素の番号と、動かし始める前の文書。
    private var move: (index: Int, base: Document)?
    private lazy var editor: InlineTextEditor = {
        let editor = InlineTextEditor(host: self)
        editor.onCommitRequested = { [weak self] in self?.commitEditing() }
        return editor
    }()

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

    /// キャンバスの大きさが変わると、書き出し PNG の寸法も変わる。
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

    // MARK: - 履歴

    func undo() {
        commitEditing()
        cancelPointerInteraction()
        guard let previous = history.undo(current: document) else { return }
        document = previous
        changed()
    }

    func redo() {
        commitEditing()
        cancelPointerInteraction()
        guard let next = history.redo(current: document) else { return }
        document = next
        changed()
    }

    /// 利用者の操作で文書を変える。変更前の文書を履歴に積む。
    private func commit(_ new: Document) {
        cancelPointerInteraction()
        history.record(previous: document)
        document = new
        changed()
    }

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    /// ポインタ操作の途中（描いている線・移動中の要素）を捨てる。ボタンを押したまま取り消し・貼り付けをされても、
    /// 古い状態を書き戻さない。移動の途中なら、移動前の状態へ戻す（半端な位置を履歴に残さない）。
    private func cancelPointerInteraction() {
        if let move {
            document = move.base
            needsDisplay = true
        }
        draft = nil
        move = nil
    }

    // MARK: - 画像

    /// 画像を背景として開く（CLI 引数・`open`）。新しいキャンバスになる（直前の状態は取り消しで戻せる）。
    @discardableResult
    func loadImage(at url: URL) -> Bool {
        guard case .success(let images) = ImageIntake.images(at: [url]), let image = images.first else { return false }
        commitEditing()
        commit(Document(background: image, backgroundRect: fitted(image.pointSize)))
        return true
    }

    /// クリップボードの画像を、中央に置く。
    @discardableResult
    func pasteImages() -> Bool {
        commitEditing()
        return place(ImageIntake.images(from: .general), at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// ファイル選択で選ばれた画像を、中央に置く。
    @discardableResult
    func addImages(at urls: [URL]) -> Bool {
        commitEditing()
        return place(ImageIntake.images(at: urls), at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// 取り込んだ画像を、`center` を中心に置く（貼り付け・ドロップ・ファイル選択で共通）。複数枚は少しずらして、全部見えるようにする。
    private func place(_ result: Result<[ImportedImage], ImageIntakeError>, at center: CGPoint) -> Bool {
        switch result {
        case .failure(let error):
            onIntakeFailure?(error)
            return false
        case .success(let images):
            cancelPointerInteraction()   // 移動の途中なら、移動前に戻してから足す
            let items = images.enumerated().map { i, image -> Item in
                let box = boxForPlacing(image, centeredAt: CGPoint(x: center.x + CGFloat(i) * 16, y: center.y + CGFloat(i) * 16))
                return Item(content: .image(image, box: box), color: CGColor(gray: 0, alpha: 1), size: 0)
            }
            commit(document.appending(contentsOf: items))
            return true
        }
    }

    /// キャンバスの 70% に収まるよう縮小し（拡大はしない）、`center` を中心にした枠。
    private func boxForPlacing(_ image: ImportedImage, centeredAt center: CGPoint) -> CGRect {
        let s = min(bounds.width * 0.7 / image.pointSize.width, bounds.height * 0.7 / image.pointSize.height, 1)
        let size = CGSize(width: image.pointSize.width * s, height: image.pointSize.height * s)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// 背景画像の枠。現在のキャンバスに収まるよう、縦横比を保って中央に置く（拡大はしない）。
    private func fitted(_ size: CGSize) -> CGRect {
        let scale = min(bounds.width / size.width, bounds.height / size.height, 1)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    // MARK: - ポインタ

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
            draft = Item(content: .pen(points: [StrokePoint(point: p, pressure: pressure(event))]), color: color.cgColor, size: brushSize)
        case .ellipse:
            draft = Item(content: .ellipse(CGRect(origin: p, size: .zero)), color: color.cgColor, size: brushSize)
        case .rect:
            draft = Item(content: .rect(CGRect(origin: p, size: .zero)), color: color.cgColor, size: brushSize)
        case .text:
            editor.begin(at: p, fontSize: 12 + brushSize * 1.5, color: color.cgColor)
        case .move:
            if let index = document.topItemIndex(at: p) {
                move = (index, document)
                NSCursor.closedHand.set()
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(event)
        if let move {
            guard let moved = move.base.translatingItem(at: move.index, by: CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y)) else { return }
            document = moved
            needsDisplay = true
            return
        }
        guard let item = draft else { return }
        switch item.content {
        case .pen(var points):
            points.append(StrokePoint(point: p, pressure: pressure(event)))
            draft?.content = .pen(points: points)
        case .ellipse:
            draft?.content = .ellipse(dragRect(to: p))
        case .rect:
            draft?.content = .rect(dragRect(to: p))
        case .text, .image:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let finished = move {
            move = nil
            window?.invalidateCursorRects(for: self)
            if location(event) != dragStart {
                history.record(previous: finished.base)
                changed()
            }
            return
        }
        guard let item = draft else { return }
        draft = nil
        switch item.content {
        case .ellipse(let r), .rect(let r):
            guard r.width >= 1, r.height >= 1 else { needsDisplay = true; return }   // 大きさのない図形は捨てる
        default:
            break
        }
        commit(document.appending(item))
    }

    private func dragRect(to p: CGPoint) -> CGRect {
        CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y), width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y))
    }

    // MARK: - 文字入力

    var isEditing: Bool { editor.isActive }

    /// 日本語入力などの変換中か（変換中のキーは、入力システムのもの）。
    var isComposingText: Bool { editor.hasMarkedText }

    /// 入力中の文字を確定する。空なら捨てる。
    func commitEditing() {
        guard let entry = editor.finish() else { return }
        let size = CanvasRenderer.textSize(entry.text, size: entry.fontSize, color: entry.color)
        let item = Item(content: .text(entry.text, box: CGRect(origin: entry.anchor, size: size)), color: entry.color, size: entry.fontSize)
        commit(document.appending(item))
    }

    func cancelEditing() {
        editor.cancel()
    }

    // MARK: - ドロップ

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageIntake.canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageIntake.canAccept(sender.draggingPasteboard) ? .copy : []
    }

    /// ドロップした位置を中心に、画像を足す。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        commitEditing()
        return place(ImageIntake.images(from: sender.draggingPasteboard), at: convert(sender.draggingLocation, from: nil))
    }

    // MARK: - 描画と書き出し

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        CanvasRenderer.drawBackdrop(transparent: transparent, bounds: bounds, in: ctx)
        CanvasRenderer.drawContent(document, draft: draft, in: ctx)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    /// 現在のキャンバス全体の PNG。入力中の文字は、確定してから含める。生成できなければ `nil`。
    func renderPNG() -> Data? {
        commitEditing()
        return CanvasRenderer.pngData(document, size: bounds.size, transparent: transparent)
    }
}
