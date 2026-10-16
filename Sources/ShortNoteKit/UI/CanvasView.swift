import AppKit

/// 描画ツール。`rawValue` は、ツールバーのセグメントの番号（左から）。キーの番号（1〜6）とは別で、並びは SPEC §4 のとおり。
enum Tool: Int, CaseIterable {
    case pen, line, ellipse, rect, text, move
}

/// キャンバス。ポインタ入力を、`Document` の変更（履歴つき）につなぐ。描画は `CanvasRenderer`、文字入力は `InlineTextEditor` が行う。
/// 座標は左上原点（`isFlipped`）。ウィンドウを広げても、描いた内容は左上から動かない。
final class CanvasView: NSView {
    /// キャンバスの最小の大きさ（ポイント）。ウィンドウはこれより小さくできない。
    static let minimumSize = CanvasSize.minimum.points

    var tool: Tool = .pen {
        didSet {
            commitEditing()
            selectedImage = nil
            window?.invalidateCursorRects(for: self)
        }
    }
    var color: NSColor = .black
    var brushSize: CGFloat = 4
    /// 円・四角を、枠だけにするか、塗りつぶすか（円と四角で別々。保存しない。SPEC §3.2.2）。
    var fillEllipse = false
    var fillRect = false
    /// 文字サイズ（ブラシサイズとは別）。入力中に変えると、入力中の文字の大きさも変わる。
    var textSize: CGFloat = TextSize.default {
        didSet { editor.setFontSize(textSize) }
    }
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

    private(set) var document = Document()
    private var history = History<Document>()
    private var draft: Item?
    private var dragStart = CGPoint.zero
    /// 移動ツールで、動かしている要素の番号と、動かし始める前の文書。
    private var move: (index: Int, base: Document)?
    /// 移動ツールで選ばれている画像の番号（要素の番号）。四隅に取っ手が出る（SPEC §3.2.3）。保存しない。
    private(set) var selectedImage: Int? {
        didSet { if oldValue != selectedImage { needsDisplay = true } }
    }
    /// 取っ手をドラッグしている角と、掴んだ位置から角までの差（`move` と同時に立つ）。
    private var resizing: (corner: ImageResize.Corner, offset: CGSize)?
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
        selectedImage = nil
        guard let previous = history.undo(current: document) else { return }
        document = previous
        changed()
    }

    func redo() {
        commitEditing()
        cancelPointerInteraction()
        selectedImage = nil
        guard let next = history.redo(current: document) else { return }
        document = next
        changed()
    }

    /// 描いたもの（要素）をすべて消す。背景画像は残す。入力中の文字は、確定してから消す（取り消すと文字ごと戻る）。
    /// 消すものが無いときは何もしない（履歴にも積まない）。
    func clearCanvas() {
        commitEditing()
        cancelPointerInteraction()
        selectedImage = nil
        guard let cleared = document.clearingItems() else { return }
        commit(cleared)
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
        resizing = nil
    }

    // MARK: - エージェントの操作（SPEC §3.7）
    //
    // 人の入力・ドラッグの途中でも、断らず、壊さず、捨てず、勝手に確定しない。人の途中の状態は、`document` の外
    // （入力中の文字、ドラッグ中の線・図形）か、`move`（動かしている要素。`document` は、`move.base` から作り直される）にある。

    /// 確定済みの文書。移動のドラッグ中は、動かす前（半端な位置は、確定していない）。
    var committedDocument: Document { move?.base ?? document }

    /// 人が、文字の入力か、ドラッグ（描く・動かす）の途中か。
    var isInteracting: Bool { editor.isActive || draft != nil || move != nil }

    /// 要素を、手前に足す。取り消しの 1 段（確定した順）。ドラッグ中の線・図形と、入力中の文字は続き、確定したとき、これらの上に重なる。
    /// 移動のドラッグ中は、動かす前の文書（`move.base`）にも足す。足さないと、次のドラッグ操作で `document` が作り直されたとき、消える。
    func appendFromAgent(_ items: [Item]) {
        guard !items.isEmpty else { return }
        if let current = move {
            history.record(previous: current.base)   // 取り消しで戻る先は、動かす前（足す前）の状態
            move = (current.index, current.base.appending(contentsOf: items))
            document = document.appending(contentsOf: items)
        } else {
            history.record(previous: document)
            document = document.appending(contentsOf: items)
        }
        changed()
    }

    /// 確定済みの要素を消す（背景は残す）。入力中の文字・ドラッグ中の線・図形は消さない。
    /// 移動のドラッグ中は、動かしている要素も確定済みなので消え、そのドラッグは終わる。消すものが無ければ `false`。
    @discardableResult
    func clearFromAgent() -> Bool {
        let base = committedDocument
        guard let cleared = base.clearingItems() else { return false }
        move = nil
        resizing = nil
        selectedImage = nil
        history.record(previous: base)
        document = cleared
        window?.invalidateCursorRects(for: self)
        changed()
        return true
    }

    /// 確定済みの内容の PNG。入力中の文字は、確定せず、含めない。
    func renderCommittedPNG() -> Data? {
        CanvasRenderer.pngData(committedDocument, size: bounds.size, transparent: transparent)
    }

    // MARK: - 画像

    /// 画像を背景として開く（CLI 引数・`open`）。新しいキャンバスになる（直前の状態は取り消しで戻せる）。
    @discardableResult
    func loadImage(at url: URL) -> Bool {
        guard case .success(let image) = ImageIntake.image(at: url) else { return false }
        commitEditing()
        selectedImage = nil
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
        Placement.fitted(size, in: bounds.size)
    }

    // MARK: - ポインタ

    /// ポインタの位置（キャンバスの座標）。キャンバスの外へ出たら、縁の位置に丸める（SPEC §3.2）。
    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).clamped(to: bounds)
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
            draft = Item(content: .ellipse(CGRect(origin: p, size: .zero)), color: color.cgColor, size: brushSize, filled: fillEllipse)
        case .rect:
            draft = Item(content: .rect(CGRect(origin: p, size: .zero)), color: color.cgColor, size: brushSize, filled: fillRect)
        case .line:
            draft = Item(content: .line(from: p, to: p), color: color.cgColor, size: brushSize)
        case .text:
            beginText(at: p)
        case .move:
            if let index = selectedImage, let box = document.imageBox(at: index), let corner = ImageResize.corner(at: p, in: box) {
                let at = corner.point(in: box)
                move = (index, document)
                resizing = (corner, CGSize(width: at.x - p.x, height: at.y - p.y))
            } else if let index = document.topItemIndex(at: p) {
                move = (index, document)
                selectedImage = document.imageBox(at: index) != nil ? index : nil
                NSCursor.closedHand.set()
            } else {
                selectedImage = nil
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(event)
        if let move {
            if let resizing, let original = move.base.imageBox(at: move.index) {
                let pointer = CGPoint(x: p.x + resizing.offset.width, y: p.y + resizing.offset.height).clamped(to: bounds)   // 掴んだ差を足したあとも、縁に丸める（SPEC §3.2）
                let box = ImageResize.box(original: original, corner: resizing.corner, pointer: pointer, keepAspect: !event.modifierFlags.contains(.shift))
                guard let resized = move.base.resizingImage(at: move.index, to: box) else { return }
                document = resized
                needsDisplay = true
                return
            }
            guard let moved = move.base.translatingItem(at: move.index, by: CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y), keepingGrabAreaIn: bounds) else { return }
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
        case .line(let from, _):
            draft?.content = .line(from: from, to: p)
        case .text, .image:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let finished = move {
            move = nil
            resizing = nil
            window?.invalidateCursorRects(for: self)
            if document.hasMovedItem(at: finished.index, since: finished.base) {   // 上限で止まって動かなかったドラッグは、取り消しの段にしない
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
        case .line(let a, let b):
            guard hypot(b.x - a.x, b.y - a.y) >= 1 else { needsDisplay = true; return }   // 大きさのない直線は捨てる
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

    /// 文字ツールで、`point` に入力欄を開く。大きさは `textSize`、色は選んだ色。
    func beginText(at point: CGPoint) {
        editor.begin(at: point, fontSize: textSize, color: color.cgColor)
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
        drawSelectionHandles(in: ctx)
    }

    /// 選ばれた画像の、点線の枠と四隅の取っ手。画面だけの表示で、書き出し（`renderPNG`）には入らない。
    private func drawSelectionHandles(in ctx: CGContext) {
        guard tool == .move, let index = selectedImage, let box = document.imageBox(at: index) else { return }
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(box)
        ctx.setLineDash(phase: 0, lengths: [])
        let s = ImageResize.handleSize
        for corner in ImageResize.Corner.allCases {
            let p = corner.point(in: box)
            let handle = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(handle)
            ctx.stroke(handle)
        }
        ctx.restoreGState()
    }

    /// 現在のキャンバス全体の PNG。入力中の文字は、確定してから含める。生成できなければ `nil`。
    func renderPNG() -> Data? {
        commitEditing()
        return CanvasRenderer.pngData(document, size: bounds.size, transparent: transparent)
    }
}
