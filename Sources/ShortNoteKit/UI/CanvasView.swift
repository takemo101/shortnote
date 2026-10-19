import AppKit

/// 描画ツール。ツールバーのボタンの並び（ペン／直線／図形／文字／移動／ハンド）とは別で、円・四角・三角は、「図形」のボタン 1 つにまとまる（`Toolbar`）。
enum Tool: CaseIterable {
    case pen, line, ellipse, rect, triangle, text, move, hand, eraser
}

/// キャンバス。ポインタ入力を、`Document` の変更（履歴つき）につなぐ。描画は `CanvasRenderer`、文字入力は `InlineTextEditor` が行う。
/// 座標は左上原点（`isFlipped`）。ウィンドウを広げても、描いた内容は左上から動かない。
final class CanvasView: NSView {
    /// キャンバスの最小の大きさ（ポイント）。ウィンドウはこれより小さくできない。
    static let minimumSize = CanvasSize.minimum.points

    var tool: Tool = .pen {
        didSet {
            commitEditing()
            selectedItem = nil
            marquee = nil   // 範囲選択の途中で、ツールを替えたら、捨てる
            panStart = nil  // ハンドのドラッグの途中で、ツールを替えたら、止める
            eraserMarks = []; eraserLast = nil   // 消しゴムの途中で、ツールを替えたら、何も消さない
            if snapBase != nil { draft = nil }   // 整形した図形を、回している途中で、ツールを替えたら、その図形は、捨てる（ほかのツールの描き方で、図形が崩れないように）
            stopHold()                            // 整形の待ちも、同じ
            window?.invalidateCursorRects(for: self)
        }
    }
    var color: NSColor = .black
    var brushSize: CGFloat = 4
    /// 円・四角・三角を、枠だけにするか、塗りつぶすか（図形ごとに別々。保存しない。SPEC §3.2.2）。
    var fillEllipse = false
    var fillRect = false
    var fillTriangle = false
    /// 直線の矢じり（線・矢印・両端の矢印。保存しない。SPEC §3.2.2）。
    var lineArrow: Item.Arrow = .none
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
    /// ビュー（見えている範囲。拡大縮小と移動）。画面だけの状態で、保存しない。SPEC §3.2.5。
    /// 反映は、`NSView.bounds`（見えている範囲）で行う：`convert` が、ポインタの位置を、そのままキャンバスの座標にし、描画・カーソル・入力欄も、同じ座標系になる。
    /// キャンバス（書き出す範囲）は、`canvasRect`（`bounds` ではない）。
    private(set) var viewport = Viewport.identity {
        didSet { if oldValue != viewport { applyViewport(); onViewportChange?(viewport) } }
    }
    /// ビューが変わった（拡大縮小・移動・戻した。ウィンドウの大きさに合わせて収め直したときも）とき、新しいビューを渡す（倍率の帯の表示のため。SPEC §3.2.5）。
    var onViewportChange: ((Viewport) -> Void)?
    /// ハンドツールのドラッグの、始めのビューの位置と、ポインタ（ウィンドウの座標）。
    private var panStart: (origin: CGPoint, pointer: CGPoint)?
    /// 消しゴムの、印が付いた要素の番号（離すと、まとめて消える）。SPEC §3.2.6。
    private var eraserMarks: Set<Int> = [] {
        didSet { if oldValue != eraserMarks { needsDisplay = true } }
    }
    /// 消しゴムで、動かしている間の、前のポインタの位置（キャンバスの座標）。押していないときは `nil`。
    private var eraserLast: CGPoint?
    /// 消しゴムの、ポインタの半径（画面の pt。拡大縮小していても、同じ）。
    static let eraserRadius: CGFloat = 8
    /// 手書きの形の整形（SPEC §3.2.7）：止まりの待ちのタイマーと、その基準の位置。整形したあとは、元の図形と、掴んだ位置の向き（回すときの基準）。
    private var holdTimer: Timer?
    private var holdAnchor: CGPoint?
    /// 整形した図形（元）、掴んだ位置の向きと、軸からの距離（回転・拡大縮小の基準）。
    private var snapBase: (shape: RecognizedShape, startAngle: CGFloat, startDistance: CGFloat)?
    /// 待ち時間の印（SPEC §3.2.7）：ポインタのまわりの輪。`center` は、キャンバスの外へ丸めない実際の位置。
    struct HoldMark: Equatable {
        var center: CGPoint
        var since: Date
        var snapped: Bool
    }
    private(set) var holdMark: HoldMark?
    private var holdTick: Timer?
    /// 輪を出し始めるまでの時間（秒）と、輪の半径（画面の pt）。
    static let holdMarkDelay: TimeInterval = 0.12
    static let holdMarkRadius: CGFloat = 16

    /// 止めてからの経過時間 `elapsed` で、輪の円弧が、どこまで伸びているか（0〜1）。輪が出る前（`holdMarkDelay` まで）は `nil`。
    static func holdMarkProgress(elapsed: TimeInterval) -> CGFloat? {
        guard elapsed >= holdMarkDelay else { return nil }
        return CGFloat(min((elapsed - holdMarkDelay) / (holdDelay - holdMarkDelay), 1))
    }
    /// 待ちの基準にした点が、描いている線の、何番目か（止めている間に付いた、手の震えの点を、判定から外すため）。
    private var holdAnchorIndex = 0
    /// ポインタを止めたとみなす待ち時間（秒）と、動いていないとみなす距離（画面の pt）。
    static let holdDelay: TimeInterval = 0.6
    static let holdRadius: CGFloat = 3
    /// 移動ツールで、動かしている要素の番号と、動かし始める前の文書。
    private var move: (index: Int, base: Document)?
    /// 移動ツールで選ばれている要素の番号（小さい順。背景画像以外の、どの要素も選べる。範囲選択で複数になる）。保存しない。SPEC §3.2.3。
    private(set) var selectedItems: [Int] = [] {
        didSet { if oldValue != selectedItems { needsDisplay = true } }
    }
    /// 選びが 1 つのときの、その要素の番号（取っ手が出る）。複数・なしのときは `nil`。入れると、その 1 つだけの選びになる（`nil` で、選びなし）。
    private(set) var selectedItem: Int? {
        get { selectedItems.count == 1 ? selectedItems[0] : nil }
        set { selectedItems = newValue.map { [$0] } ?? [] }
    }
    /// 選びが 2 つ以上のとき、まとめて動かしている要素の番号（`move` と同時に立つ）。1 つを動かしているときは `nil`。
    private var moveGroup: [Int]?
    /// 範囲選択の、ドラッグの始点と、いまの位置（キャンバスの座標）。
    private var marquee: (start: CGPoint, current: CGPoint)?
    /// 取っ手をドラッグしているもの、掴んだ位置から取っ手までの差、掴んだ位置の角度（回転の取っ手のとき。軸から見た向き）。`move` と同時に立つ。
    private var resizing: (handle: ItemHandles.Handle, offset: CGSize, startAngle: CGFloat)?
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

    /// キャンバスの大きさが変わると、書き出し PNG の寸法も変わる。ビューの倍率と位置は保つ（見えている範囲だけ、直す）。
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        applyViewport()
        if resized { onChange?() }
    }

    override func resetCursorRects() {
        switch tool {
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .hand: addCursorRect(bounds, cursor: panStart == nil ? .openHand : .closedHand)
        case .eraser: addCursorRect(bounds, cursor: Self.eraserCursor)
        case .move: addCursorRect(bounds, cursor: .arrow)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - ビュー（SPEC §3.2.5）

    /// キャンバス（書き出す範囲）。大きさは、画面の大きさ（`frame`）で、ビューを動かしても変わらない。`bounds` は、見えている範囲。
    var canvasRect: CGRect { CGRect(origin: .zero, size: frame.size) }
    var canvasSize: CGSize { frame.size }

    private func applyViewport() {
        let fixed = viewport.clamped(viewSize: frame.size)
        if fixed != viewport { viewport = fixed; return }
        bounds = NSRect(origin: fixed.origin, size: CGSize(width: frame.width / fixed.zoom, height: frame.height / fixed.zoom))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// ビューを、等倍・動かしていない状態に戻す。
    func resetViewport() { viewport = .identity }

    /// 倍率だけを、100% に戻す。いま見えているキャンバスの範囲の中心が、画面の中央に来る
    /// （縮小したまま、キャンバスの外が中心になっていても、等倍にしたとき、キャンバスが、画面の隅に、わずかしか残らないことはない）。
    func resetZoom() {
        let visible = viewport.visibleRect(viewSize: frame.size).intersection(canvasRect)
        guard !visible.isNull else { viewport = .identity; return }
        viewport = viewport.resetZoom(centeredOn: CGPoint(x: visible.midX, y: visible.midY), viewSize: frame.size)
    }

    /// 倍率を `factor` 倍にする。`anchor`（キャンバスの座標）の点は、画面の同じ位置に残る。
    func zoomViewport(by factor: CGFloat, at anchor: CGPoint) {
        viewport = viewport.zoomed(by: factor, anchor: anchor, viewSize: frame.size)
    }

    /// 画面で `delta`（右・下が正）だけ、内容が動くように、ビューを動かす。
    func panViewport(byScreen delta: CGSize) {
        viewport = viewport.panned(byScreen: delta, viewSize: frame.size)
    }

    /// トラックパッドのピンチ：拡大縮小（ポインタの位置が動かない）。ハンドのドラッグの途中は、受け付けない（ドラッグの基準が、ずれて、ビューが跳ぶため）。
    override func magnify(with event: NSEvent) {
        guard panStart == nil else { return }
        zoomViewport(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    /// Cmd+スクロール：拡大縮小（ホイール・指を上へ回すと拡大。システムのスクロールの向きの設定には、よらない）。
    /// Cmd なしのスクロール（2 本指のスワイプ）：ビューが動く（向きは、システムの設定に従う）。ハンドのドラッグの途中は、受け付けない。
    override func scrollWheel(with event: NSEvent) {
        guard panStart == nil else { return }
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10   // マウスのホイールは、行の単位
        if event.modifierFlags.contains(.command) {
            let physicalUp = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            zoomViewport(by: exp(physicalUp * unit / 100), at: convert(event.locationInWindow, from: nil))
        } else {
            panViewport(byScreen: CGSize(width: event.scrollingDeltaX * unit, height: event.scrollingDeltaY * unit))
        }
    }

    // MARK: - 履歴

    func undo() {
        commitEditing()
        cancelPointerInteraction()
        selectedItem = nil
        guard let previous = history.undo(current: document) else { return }
        document = previous
        changed()
    }

    func redo() {
        commitEditing()
        cancelPointerInteraction()
        selectedItem = nil
        guard let next = history.redo(current: document) else { return }
        document = next
        changed()
    }

    /// 描いたもの（要素）をすべて消す。背景画像は残す。入力中の文字は、確定してから消す（取り消すと文字ごと戻る）。
    /// 消すものが無いときは何もしない（履歴にも積まない）。
    func clearCanvas() {
        commitEditing()
        cancelPointerInteraction()
        selectedItem = nil
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
        moveGroup = nil
        marquee = nil
        resizing = nil
        eraserMarks = []
        eraserLast = nil
        stopHold()
    }

    // MARK: - エージェントの操作（SPEC §3.7）
    //
    // 人の入力・ドラッグの途中でも、断らず、壊さず、捨てず、勝手に確定しない。人の途中の状態は、`document` の外
    // （入力中の文字、ドラッグ中の線・図形）か、`move`（動かしている要素。`document` は、`move.base` から作り直される）にある。

    /// 確定済みの文書。移動のドラッグ中は、動かす前（半端な位置は、確定していない）。
    var committedDocument: Document { move?.base ?? document }

    /// 人が、文字の入力か、ドラッグ（描く・動かす）の途中か。
    var isInteracting: Bool { editor.isActive || draft != nil || move != nil || marquee != nil || eraserLast != nil }

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
        moveGroup = nil
        resizing = nil
        eraserMarks = []
        eraserLast = nil
        selectedItem = nil
        history.record(previous: base)
        document = cleared
        window?.invalidateCursorRects(for: self)
        changed()
        return true
    }

    /// 確定済みの内容の PNG。入力中の文字は、確定せず、含めない。
    func renderCommittedPNG() -> Data? {
        CanvasRenderer.pngData(committedDocument, size: canvasSize, transparent: transparent)
    }

    // MARK: - 画像

    /// 画像を背景として開く（CLI 引数・`open`）。新しいキャンバスになる（直前の状態は取り消しで戻せる）。
    @discardableResult
    func loadImage(at url: URL) -> Bool {
        guard case .success(let image) = ImageIntake.image(at: url) else { return false }
        commitEditing()
        selectedItem = nil
        commit(Document(background: image, backgroundRect: fitted(image.pointSize)))
        return true
    }

    /// クリップボードの画像を、中央に置く。
    @discardableResult
    func pasteImages() -> Bool {
        commitEditing()
        return place(ImageIntake.images(from: .general), at: CGPoint(x: canvasRect.midX, y: canvasRect.midY))
    }

    /// ファイル選択で選ばれた画像を、中央に置く。
    @discardableResult
    func addImages(at urls: [URL]) -> Bool {
        commitEditing()
        return place(ImageIntake.images(at: urls), at: CGPoint(x: canvasRect.midX, y: canvasRect.midY))
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
        let s = min(canvasRect.width * 0.7 / image.pointSize.width, canvasRect.height * 0.7 / image.pointSize.height, 1)
        let size = CGSize(width: image.pointSize.width * s, height: image.pointSize.height * s)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// 背景画像の枠。現在のキャンバスに収まるよう、縦横比を保って中央に置く（拡大はしない）。
    private func fitted(_ size: CGSize) -> CGRect {
        Placement.fitted(size, in: canvasSize)
    }

    // MARK: - ポインタ

    /// ポインタの位置（キャンバスの座標）。キャンバスの外へ出たら、縁の位置に丸める（SPEC §3.2）。
    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).clamped(to: canvasRect)
    }

    /// 筆圧はタブレット入力のときだけ使う。トラックパッドの感圧では太さを変えない。
    private func pressure(_ event: NSEvent) -> CGFloat {
        event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1
    }

    override func mouseDown(with event: NSEvent) {
        commitEditing()
        marquee = nil       // 前の範囲選択が、離す操作を受けずに残っていたら、捨てる（次のドラッグを、乗っ取らないように）
        stopHold()          // 整形の待ちも、同じ
        eraserMarks = []; eraserLast = nil   // 消しゴムも、同じ（離す操作が届かなかったとき、印のついた要素を、次のドラッグで、消さないように）
        panStart = nil      // ハンドのドラッグも、同じ（離す操作が届かなかったとき、次のドラッグが、すべてパンにならないように）
        let p = location(event)
        dragStart = p
        switch tool {
        case .pen:
            draft = Item(content: .pen(points: [StrokePoint(point: p, pressure: pressure(event))]), color: color.cgColor, size: brushSize)
            scheduleHold(at: convert(event.locationInWindow, from: nil))
        case .ellipse:
            draft = Item(content: .ellipse(CGRect(origin: p, size: .zero)), color: color.cgColor, size: brushSize, filled: fillEllipse)
        case .rect:
            draft = Item(content: .rect(CGRect(origin: p, size: .zero)), color: color.cgColor, size: brushSize, filled: fillRect)
        case .triangle:
            draft = Item(content: .triangle(CGRect(origin: p, size: .zero)), color: color.cgColor, size: brushSize, filled: fillTriangle)
        case .line:
            draft = Item(content: .line(from: p, to: p), color: color.cgColor, size: brushSize, arrow: lineArrow)
        case .text:
            beginText(at: p)
        case .eraser:
            eraserLast = p
            markErased(from: p, to: p)
        case .hand:
            panStart = (viewport.origin, event.locationInWindow)
            NSCursor.closedHand.set()
        case .move:
            if let index = selectedItem, let target = document.resizeTarget(at: index),
               let handle = ItemHandles.handle(at: p, in: target.shape, canvas: canvasRect, scale: viewport.scale),
               let at = ItemHandles.point(of: handle, in: target.shape, canvas: canvasRect, scale: viewport.scale) {
                move = (index, document)
                resizing = (handle, CGSize(width: at.x - p.x, height: at.y - p.y), ItemHandles.angle(from: ItemHandles.center(of: target.shape), to: p))
            } else if !event.modifierFlags.contains(.shift), let index = document.topItemIndex(at: p) {
                move = (index, document)
                if selectedItems.count > 1, selectedItems.contains(index) {
                    moveGroup = selectedItems                       // 選ばれた要素の、どれかを掴んだ：全部、一緒に動く
                } else {
                    moveGroup = nil
                    selectedItem = document.resizeTarget(at: index) != nil ? index : nil
                }
                NSCursor.closedHand.set()
            } else {
                // 何もない所（または、Shift つきで始めた）：範囲選択。選びは、いったん外す
                selectedItems = []
                marquee = (p, p)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let pan = panStart {
            // ハンドツール：ポインタ（ウィンドウの座標。上が正）の動きの分だけ、内容が動く。始めの位置からの差で決める（動かしている間に、位置が、ずれていかない）
            let delta = CGSize(width: event.locationInWindow.x - pan.pointer.x, height: -(event.locationInWindow.y - pan.pointer.y))
            viewport = Viewport(zoom: viewport.zoom, origin: pan.origin).panned(byScreen: delta, viewSize: frame.size)
            return
        }
        let p = location(event)
        if let last = eraserLast {
            markErased(from: last, to: p)
            eraserLast = p
            return
        }
        if marquee != nil {
            marquee?.current = p
            needsDisplay = true
            return
        }
        if let move {
            if let resizing, let target = move.base.resizeTarget(at: move.index) {
                if resizing.handle == .rotate {
                    // 軸から見た、掴んだ位置の向きと、いまのポインタの向きの差だけ回す。Shift なら 15° きざみ
                    var delta = ItemHandles.normalized(ItemHandles.angle(from: ItemHandles.center(of: target.shape), to: p) - resizing.startAngle)
                    if event.modifierFlags.contains(.shift) {
                        if case .box(_, let base) = target.shape { delta = ItemHandles.snapped(base + delta) - base } else { delta = ItemHandles.snapped(delta) }
                    }
                    // 回した結果、掴める範囲が、キャンバスの中にほとんど残らなくなる向きへは、回さない（直前の向きのまま。移動と同じ 16 pt の規則）
                    guard let rotated = move.base.rotating(itemAt: move.index, by: delta),
                          rotated.keepsGrabArea(at: move.index, since: move.base, in: canvasRect) else { return }
                    document = rotated
                    needsDisplay = true
                    return
                }
                // 掴んだ差を足したあとも、縁に丸める（SPEC §3.2）。いま縁の外にある取っ手は、その位置まで（触っただけで、縁へ跳ねない）
                let grabbedAt = ItemHandles.point(of: resizing.handle, in: target.shape, canvas: canvasRect, scale: viewport.scale) ?? p
                let pointer = CGPoint(x: p.x + resizing.offset.width, y: p.y + resizing.offset.height).clamped(to: canvasRect.union(CGRect(origin: grabbedAt, size: .zero)))
                let item = move.base.items[move.index]
                if target.kind == .text, case .box(let box, let angle) = target.shape, case .corner(let corner) = resizing.handle, case .text(let text, _) = item.content {
                    // 文字は、常に等倍：枠の倍率で、文字の大きさを変え、その大きさの枠を、反対側の角が動かないよう置く
                    let range = CGFloat(OpsParser.fontSizeRange.lowerBound)...CGFloat(OpsParser.fontSizeRange.upperBound)
                    let scaled = ItemHandles.scaledText(original: box, rotation: angle, corner: corner, pointer: pointer, fontSize: item.size, fontRange: range) {
                        CanvasRenderer.textSize(text, size: $0, color: item.color)
                    }
                    guard let resized = move.base.applying(.box(scaled.box, rotation: angle), fontSize: scaled.fontSize, toItemAt: move.index) else { return }
                    document = resized
                    needsDisplay = true
                    return
                }
                let keepAspect = target.keepsAspect != event.modifierFlags.contains(.shift)   // Shift は、既定と逆
                // 形が下限を割る位置（直線が 1 pt 未満など）では、直前の形のまま
                guard let shape = ItemHandles.resized(target.shape, handle: resizing.handle, pointer: pointer, keepAspect: keepAspect, minSide: target.minSide),
                      let resized = move.base.applying(shape, toItemAt: move.index) else { return }
                document = resized
                needsDisplay = true
                return
            }
            if let group = moveGroup {
                guard let moved = move.base.translatingItems(at: group, by: CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y), keepingGrabAreaIn: canvasRect) else { return }
                document = moved
                needsDisplay = true
                return
            }
            guard let moved = move.base.translatingItem(at: move.index, by: CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y), keepingGrabAreaIn: canvasRect) else { return }
            document = moved
            needsDisplay = true
            return
        }
        if let snap = snapBase, let current = draft {
            // 整形したあと：軸から見たポインタの、向きの変化の分だけ回り、距離の比の分だけ拡大縮小する（掴んだ位置からの差）。
            // 掴める範囲が、キャンバスの中にほとんど残らなくなる向きへは、動かさない（移動ツールの回転と同じ規則。直前のまま）
            holdMark?.center = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            let pivot = snap.shape.pivot
            let distance = hypot(p.x - pivot.x, p.y - pivot.y)
            guard distance >= 1 else { return }   // 軸の真上：向きが決まらない
            let delta = ItemHandles.normalized(ItemHandles.angle(from: pivot, to: p) - snap.startAngle)
            let scale = snap.startDistance >= 4 ? distance / snap.startDistance : 1   // 軸の近くで止めたときは、拡大縮小しない（距離の比が、暴れるため）
            let turned = snap.shape.transformed(by: delta, scale: scale).item(color: current.color, size: current.size)
            let before = document.appending(current), after = document.appending(turned)
            guard after.keepsGrabArea(at: after.items.count - 1, since: before, in: canvasRect) else { return }
            draft = turned
            return
        }
        guard let item = draft else { return }
        switch item.content {
        case .pen(var points):
            points.append(StrokePoint(point: p, pressure: pressure(event)))
            draft?.content = .pen(points: points)
            // 動いた（画面で 3 pt を超えて。キャンバスの外の位置で比べる：縁に丸めた位置では、外で動かし続けても、止まったことになる）：待ち直す
            let raw = convert(event.locationInWindow, from: nil)
            if let anchor = holdAnchor, hypot(raw.x - anchor.x, raw.y - anchor.y) > Self.holdRadius * viewport.scale { scheduleHold(at: raw) }
        case .ellipse:
            draft?.content = .ellipse(dragRect(to: p))
        case .rect:
            draft?.content = .rect(dragRect(to: p))
        case .triangle:
            draft?.content = .triangle(dragRect(to: p))
        case .line(let from, _):
            draft?.content = .line(from: from, to: p)
        case .text, .image:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        stopHold()   // 整形した図形（`draft`）は、そのまま確定する（下の draft の確定）
        if eraserLast != nil {
            finishErasing()
            return
        }
        if panStart != nil {
            panStart = nil
            window?.invalidateCursorRects(for: self)
            if tool == .hand { NSCursor.openHand.set() }
            return
        }
        if let area = marquee {
            // 範囲選択を終える：外接する範囲が、範囲にすっぽり入っている要素を選ぶ（取り消しの段にはならない）
            marquee = nil
            let rect = CGRect(x: min(area.start.x, area.current.x), y: min(area.start.y, area.current.y),
                              width: abs(area.current.x - area.start.x), height: abs(area.current.y - area.start.y))
            selectedItems = document.itemIndices(containedIn: rect, canvas: canvasRect)
            needsDisplay = true
            return
        }
        if let finished = move {
            let group = moveGroup
            move = nil
            moveGroup = nil
            resizing = nil
            window?.invalidateCursorRects(for: self)
            if document.hasChangedItems(at: group ?? [finished.index], since: finished.base) {   // 上限で止まって動かなかったドラッグ、変わらなかった取っ手の操作は、取り消しの段にしない
                history.record(previous: finished.base)
                changed()
            }
            return
        }
        guard let item = draft else { return }
        draft = nil
        switch item.content {
        case .ellipse(let r), .rect(let r), .triangle(let r):
            guard r.width >= 1, r.height >= 1 else { needsDisplay = true; return }   // 大きさのない図形は捨てる
        case .line(let a, let b):
            guard hypot(b.x - a.x, b.y - a.y) >= 1 else { needsDisplay = true; return }   // 大きさのない直線は捨てる
        default:
            break
        }
        commit(document.appending(item))
    }

    // MARK: - 手書きの形の整形（SPEC §3.2.7）

    /// ペンで、動かさずに待つ：その位置を基準に、待ち直す。待ち時間の印も、その位置から、出し直す。
    private func scheduleHold(at p: CGPoint) {
        holdTimer?.invalidate()
        holdAnchor = p
        if case .pen(let points)? = draft?.content { holdAnchorIndex = max(points.count - 1, 0) }
        guard tool == .pen, snapBase == nil else { holdTimer = nil; clearHoldMark(); return }
        let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in self?.snapHeldStroke() }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
        invalidateHoldMark()                      // 前の位置の輪を消す
        holdMark = HoldMark(center: p, since: Date(), snapped: false)
        if holdTick == nil {                      // 輪の円弧を伸ばすための、描き直し
            let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.invalidateHoldMark() }
            RunLoop.main.add(tick, forMode: .common)
            holdTick = tick
        }
    }

    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdAnchor = nil
        snapBase = nil
        clearHoldMark()
    }

    private func clearHoldMark() {
        holdTick?.invalidate()
        holdTick = nil
        if holdMark != nil { invalidateHoldMark(); holdMark = nil }
    }

    /// 輪のまわりだけを、描き直す。
    private func invalidateHoldMark() {
        guard let mark = holdMark else { return }
        let r = (Self.holdMarkRadius + 6) * viewport.scale
        setNeedsDisplay(NSRect(x: mark.center.x - r, y: mark.center.y - r, width: 2 * r, height: 2 * r))
    }

    /// 止めたまま、待ち時間がたった：いま描いている線を、円・四角・三角・直線・矢印に見えれば、その図形に置き替える（見えなければ、何もしない。輪は消える）。
    /// 置き替えたあと、ボタンを押したまま動かすと、図形が回り、拡大縮小する。
    func snapHeldStroke() {
        holdTimer = nil
        // 止めている間に付いた、手の震えの点（基準の点より後）は、形の判定から外す（線が、伸びて、直線に見えなくなるため）
        guard tool == .pen, snapBase == nil, let current = draft, case .pen(let points) = current.content, points.count >= 4, let last = points.last?.point,
              let shape = ShapeRecognizer.recognize(points.prefix(holdAnchorIndex + 1).map(\.point)) else { clearHoldMark(); return }
        draft = shape.item(color: current.color, size: current.size)
        let pivot = shape.pivot
        snapBase = (shape, ItemHandles.angle(from: pivot, to: last), hypot(last.x - pivot.x, last.y - pivot.y))
        holdTick?.invalidate()
        holdTick = nil
        holdMark?.snapped = true                  // 輪は、閉じて、ポインタについてくる
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)   // 触覚（トラックパッドがあれば）
        needsDisplay = true
    }

    // MARK: - 消しゴム（SPEC §3.2.6）

    /// 消しゴムのカーソル：小さな輪（白い縁つきの黒い輪。どの背景でも見える）。
    static let eraserCursor: NSCursor = {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = rect.insetBy(dx: 3, dy: 3)
            NSColor.white.setStroke()
            let outer = NSBezierPath(ovalIn: ring); outer.lineWidth = 3.5; outer.stroke()
            NSColor.black.setStroke()
            let inner = NSBezierPath(ovalIn: ring); inner.lineWidth = 1.5; inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    /// ポインタの動き（`a` から `b`）が触れた要素に、印を付ける（まだ消さない）。背景の画像は、要素ではないので、対象にならない。
    private func markErased(from a: CGPoint, to b: CGPoint) {
        let radius = Self.eraserRadius * viewport.scale
        var marks = eraserMarks
        for (index, item) in document.items.enumerated() where !marks.contains(index) && item.isTouched(from: a, to: b, radius: radius) {
            marks.insert(index)
        }
        eraserMarks = marks
    }

    /// 離したとき：印の付いた要素を、まとめて消す（取り消しの 1 段）。何にも触れなかったときは、何もしない。
    private func finishErasing() {
        let marks = eraserMarks
        eraserMarks = []
        eraserLast = nil
        needsDisplay = true
        guard let erased = document.removingItems(at: marks) else { return }
        selectedItems = []
        commit(erased)
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
        return place(ImageIntake.images(from: sender.draggingPasteboard), at: dropLocation(sender.draggingLocation))
    }

    /// ドロップした位置（ウィンドウの座標）を、キャンバスの座標に。ポインタと同じく、キャンバスの縁に丸める（暗い外側へ落としても、キャンバスの外へは置かない）。
    func dropLocation(_ windowPoint: CGPoint) -> CGPoint {
        convert(windowPoint, from: nil).clamped(to: canvasRect)
    }

    // MARK: - 描画と書き出し

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = viewport.scale   // 画面の 1 pt が、キャンバスの何 pt か（枠・取っ手の画面での大きさを、拡大縮小で変えない）
        if !viewport.isIdentity {
            ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)   // キャンバスの外は、暗い色
            ctx.fill(bounds)
        }
        CanvasRenderer.drawBackdrop(transparent: transparent, bounds: canvasRect, in: ctx)
        ctx.saveGState()
        ctx.clip(to: canvasRect)   // 書き出しと同じく、キャンバスの外へはみ出した分は、出さない
        CanvasRenderer.drawContent(document, draft: draft, faded: eraserMarks, in: ctx)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(s)
        ctx.stroke(canvasRect.insetBy(dx: 0.5 * s, dy: 0.5 * s))
        drawSelectionHandles(in: ctx)
        drawMultiSelection(in: ctx)
        drawHoldMark(in: ctx)
    }

    /// 待ち時間の印（SPEC §3.2.7）：ポインタのまわりの輪。暗い縁の上に、明るい円弧（真上から時計回りに、整形までの時間で 1 周）。整形したら、閉じた輪（アクセントの色）。
    /// 画面だけの表示で、書き出し（`renderPNG`）には入らない。大きさは、拡大縮小しても、画面で同じ。
    private func drawHoldMark(in ctx: CGContext) {
        guard tool == .pen, let mark = holdMark else { return }
        let progress: CGFloat
        if mark.snapped { progress = 1 } else if let p = Self.holdMarkProgress(elapsed: Date().timeIntervalSince(mark.since)) { progress = p } else { return }
        let s = viewport.scale, radius = Self.holdMarkRadius * s
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(5.5 * s)
        ctx.strokeEllipse(in: CGRect(x: mark.center.x - radius, y: mark.center.y - radius, width: 2 * radius, height: 2 * radius))
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2.5 * s)
        let steps = max(Int((progress * 60).rounded(.up)), 1)
        for i in 0...steps {   // 折れ線で、円弧を描く（反転したビューでの、向きの取り違えを避ける）
            let a = -CGFloat.pi / 2 + 2 * .pi * progress * CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: mark.center.x + radius * cos(a), y: mark.center.y + radius * sin(a))
            if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
        }
        ctx.strokePath()
    }

    /// 選ばれた要素の取っ手。点線の枠（画像・円・四角・文字は、回した向きのまま。ペンは外接する範囲）、大きさの取っ手（四隅、直線は両端）、
    /// 回転の取っ手（丸と、枠への線）。画面だけの表示で、書き出し（`renderPNG`）には入らない。
    private func drawSelectionHandles(in ctx: CGContext) {
        guard tool == .move, let index = selectedItem, let target = document.resizeTarget(at: index) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(viewport.scale)
        switch target.shape {
        case .box(let box, let angle):
            ctx.saveGState()
            let c = ItemHandles.center(of: target.shape)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: angle)
            ctx.translateBy(x: -c.x, y: -c.y)
            ctx.setLineDash(phase: 0, lengths: [4 * viewport.scale, 3 * viewport.scale])
            ctx.stroke(box)
            ctx.restoreGState()
        case .stroke(let frame):
            ctx.setLineDash(phase: 0, lengths: [4 * viewport.scale, 3 * viewport.scale])
            ctx.stroke(frame)
            ctx.setLineDash(phase: 0, lengths: [])
        case .line:
            break
        }
        let knob = ItemHandles.rotationHandle(of: target.shape, canvas: canvasRect, scale: viewport.scale)
        ctx.move(to: knob.stem)
        ctx.addLine(to: knob.handle)
        ctx.strokePath()
        let r = ItemHandles.handleSize * viewport.scale / 2
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        let circle = CGRect(x: knob.handle.x - r, y: knob.handle.y - r, width: 2 * r, height: 2 * r)
        ctx.fillEllipse(in: circle)
        ctx.strokeEllipse(in: circle)
        let s = ItemHandles.handleSize * viewport.scale
        for handle in ItemHandles.handles(of: target.shape, scale: viewport.scale) where handle != .rotate {
            guard let p = ItemHandles.point(of: handle, in: target.shape, canvas: canvasRect, scale: viewport.scale) else { continue }
            let square = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            ctx.fill(square)
            ctx.stroke(square)
        }
    }

    /// 2 つ以上選ばれているとき：それぞれの点線の枠と、全体を囲む点線の枠（大きさ・回転の取っ手は無い）。範囲選択の途中は、範囲の枠と薄い色。
    /// 画面だけの表示で、書き出し（`renderPNG`）には入らない。
    private func drawMultiSelection(in ctx: CGContext) {
        guard tool == .move else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(viewport.scale)
        ctx.setLineDash(phase: 0, lengths: [4 * viewport.scale, 3 * viewport.scale])
        let frames = selectedItems.count > 1 ? selectedItems.compactMap { document.items.indices.contains($0) ? document.items[$0].bounds : nil } : []
        for frame in frames { ctx.stroke(frame) }
        if let first = frames.first {
            let all = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -3 * viewport.scale, dy: -3 * viewport.scale)
            ctx.setLineWidth(1.5 * viewport.scale)
            ctx.stroke(all)
        }
        if let area = marquee {
            let rect = CGRect(x: min(area.start.x, area.current.x), y: min(area.start.y, area.current.y),
                              width: abs(area.current.x - area.start.x), height: abs(area.current.y - area.start.y))
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(rect)
            ctx.setLineWidth(viewport.scale)
            ctx.stroke(rect)
        }
    }

    /// 現在のキャンバス全体の PNG。入力中の文字は、確定してから含める。生成できなければ `nil`。
    func renderPNG() -> Data? {
        commitEditing()
        return CanvasRenderer.pngData(document, size: canvasSize, transparent: transparent)
    }
}
