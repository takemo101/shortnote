import CoreGraphics

/// キャンバスの内容。背景画像と、重なり順（後ろほど手前）の要素。値型で、変更は新しい値を返す。
/// 取り消し・やり直しの単位でもある（履歴には、変更前の `Document` を積む）。
struct Document {
    private(set) var background: ImportedImage?
    /// 背景画像の位置。読み込み時に確定し、ウィンドウの大きさを変えても動かさない（描いた内容とずれないように）。
    private(set) var backgroundRect: CGRect
    private(set) var items: [Item]

    init(background: ImportedImage? = nil, backgroundRect: CGRect = .zero, items: [Item] = []) {
        self.background = background
        self.backgroundRect = backgroundRect
        self.items = items
    }

    func appending(_ item: Item) -> Document {
        appending(contentsOf: [item])
    }

    func appending(contentsOf newItems: [Item]) -> Document {
        var copy = self
        copy.items.append(contentsOf: newItems)
        return copy
    }

    /// 移動ツールが要素を掴める範囲の、外接する範囲の外側への余白（pt）。
    static let grabSlop: CGFloat = 4
    /// 動かした要素の掴める範囲が、キャンバスの中に残る長さの下限（pt）。
    static let keptInCanvas: CGFloat = 16

    /// `index` の要素を、平行移動したものにして返す。範囲外なら `nil`。
    /// 動かす量は、要素の掴める範囲がキャンバスの中に残る長さを、軸ごとに下回らないよう制限する（`limited(_:for:in:keep:)`）。
    func translatingItem(at index: Int, by d: CGSize, keepingGrabAreaIn canvas: CGRect) -> Document? {
        guard items.indices.contains(index) else { return nil }
        var copy = self
        let area = items[index].bounds.insetBy(dx: -Self.grabSlop, dy: -Self.grabSlop)
        copy.items[index] = items[index].translated(by: Self.limited(d, for: area, in: canvas, keep: Self.keptInCanvas))
        return copy
    }

    /// `d` だけ動かしたとき、`area`（掴める範囲）が `canvas` の中に残る長さが、軸ごとに、
    /// `min(keep, area の大きさ, いまキャンバスの中にある分)` を下回らないように、`d` を制限したもの。
    /// いまの位置（`d` が 0）は、必ず許される。
    static func limited(_ d: CGSize, for area: CGRect, in canvas: CGRect, keep: CGFloat) -> CGSize {
        func limit(_ delta: CGFloat, _ a0: CGFloat, _ length: CGFloat, _ c0: CGFloat, _ c1: CGFloat) -> CGFloat {
            let a1 = a0 + length
            let inside = max(0, min(a1, c1) - max(a0, c0))
            let k = min(keep, length, inside)
            return min(max(delta, c0 + k - a1), c1 - k - a0)
        }
        return CGSize(
            width: limit(d.width, area.minX, area.width, canvas.minX, canvas.maxX),
            height: limit(d.height, area.minY, area.height, canvas.minY, canvas.maxY)
        )
    }

    /// `index` の要素が、`base`（動かす前の文書）から変わっているか（位置・形・回転角・文字の大きさ）。動かせる範囲の上限で止まって、動かなかったときは `false`。
    func hasChangedItem(at index: Int, since base: Document) -> Bool {
        guard items.indices.contains(index), base.items.indices.contains(index) else { return false }
        return !items[index].hasSameGeometry(as: base.items[index])
    }

    /// `indices`（範囲外の番号は除く）の要素を、まとめて平行移動したものを返す。1 つも無ければ `nil`。
    /// 動かす量は、**どの要素も**、掴める範囲（外接する範囲＋余白）が、16 pt の規則（`limited`）を満たすよう、軸ごとに、全員が許す幅の共通部分に収める
    /// （全員が同じだけ動くので、位置関係は崩れない。和集合にだけ規則を当てると、離れた要素が、キャンバスの外へ完全に出て、掴めなくなる）。
    func translatingItems(at indices: [Int], by d: CGSize, keepingGrabAreaIn canvas: CGRect) -> Document? {
        let valid = indices.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return nil }
        var dx = d.width, dy = d.height
        for index in valid {
            let area = items[index].bounds.insetBy(dx: -Self.grabSlop, dy: -Self.grabSlop)
            let x = Self.allowed(area.minX, area.width, canvas.minX, canvas.maxX, keep: Self.keptInCanvas)
            let y = Self.allowed(area.minY, area.height, canvas.minY, canvas.maxY, keep: Self.keptInCanvas)
            dx = min(max(dx, x.lowerBound), x.upperBound)
            dy = min(max(dy, y.lowerBound), y.upperBound)
        }
        var copy = self
        for index in valid { copy.items[index] = items[index].translated(by: CGSize(width: dx, height: dy)) }
        return copy
    }

    /// 1 軸で、掴める範囲（`a0` から長さ `length`）が、キャンバス（`c0`〜`c1`）の中に `min(keep, length, いまの中にある分)` 以上残る、動かす量の幅。0 を必ず含む。
    private static func allowed(_ a0: CGFloat, _ length: CGFloat, _ c0: CGFloat, _ c1: CGFloat, keep: CGFloat) -> ClosedRange<CGFloat> {
        let a1 = a0 + length
        let inside = max(0, min(a1, c1) - max(a0, c0))
        let k = min(keep, length, inside)
        return (c0 + k - a1)...(c1 - k - a0)
    }

    /// `indices` のどれかが、`base` から変わっているか。
    func hasChangedItems(at indices: [Int], since base: Document) -> Bool {
        indices.contains { hasChangedItem(at: $0, since: base) }
    }

    /// 外接する範囲（`bounds`）の、キャンバスの中にある部分が、`rect` にすっぽり入っている要素の番号（小さい順）。範囲選択に使う。
    /// キャンバスの縁より外へはみ出した分（線の太さ・縁に触れて描いた図形）は、数えない（範囲は、縁に丸められるので、はみ出した要素が、選べなくなる）。
    /// キャンバスの中に、まったく無い要素は、選ばれない。
    func itemIndices(containedIn rect: CGRect, canvas: CGRect) -> [Int] {
        items.indices.filter { index in
            let visible = items[index].bounds.intersection(canvas)
            return !visible.isNull && rect.contains(visible)
        }
    }

    /// `index` の要素（回したあと）の掴める範囲（外接する範囲＋4 pt）が、キャンバスの中に残る長さが、軸ごとに、
    /// `min(16 pt, 範囲の長さ, `base`（回す前）でキャンバスの中にあった分)` を下回らないか。移動と同じ規則（`limited`）を、回転にも当てる
    /// （回して、キャンバスの外へ出てしまい、掴めなくなるのを防ぐ）。
    func keepsGrabArea(at index: Int, since base: Document, in canvas: CGRect) -> Bool {
        guard items.indices.contains(index), base.items.indices.contains(index) else { return true }
        let area = items[index].bounds.insetBy(dx: -Self.grabSlop, dy: -Self.grabSlop)
        let old = base.items[index].bounds.insetBy(dx: -Self.grabSlop, dy: -Self.grabSlop)
        func inside(_ a0: CGFloat, _ length: CGFloat, _ c0: CGFloat, _ c1: CGFloat) -> CGFloat { max(0, min(a0 + length, c1) - max(a0, c0)) }
        let x = inside(area.minX, area.width, canvas.minX, canvas.maxX), oldX = inside(old.minX, old.width, canvas.minX, canvas.maxX)
        let y = inside(area.minY, area.height, canvas.minY, canvas.maxY), oldY = inside(old.minY, old.height, canvas.minY, canvas.maxY)
        return x >= min(Self.keptInCanvas, area.width, oldX) - 1e-9 && y >= min(Self.keptInCanvas, area.height, oldY) - 1e-9
    }

    /// `index` の要素の、取っ手の操作（大きさの変更・回転）に使う形と規則。範囲外・背景画像（要素ではない）は `nil`。
    /// ペンは、点の外接する範囲（線の太さを含めない）だけを持つ（大きさの取っ手は無い）。
    func resizeTarget(at index: Int) -> ItemHandles.Target? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        switch item.content {
        case .image(_, let box):
            return ItemHandles.Target(kind: .image, shape: .box(box, rotation: item.rotation), keepsAspect: true, minSide: ItemHandles.imageMinSide)
        case .ellipse(let rect):
            return ItemHandles.Target(kind: .ellipse, shape: .box(rect, rotation: item.rotation), keepsAspect: false, minSide: ItemHandles.shapeMinSide)
        case .rect(let rect):
            return ItemHandles.Target(kind: .rect, shape: .box(rect, rotation: item.rotation), keepsAspect: false, minSide: ItemHandles.shapeMinSide)
        case .text(_, let box):
            return ItemHandles.Target(kind: .text, shape: .box(box, rotation: item.rotation), keepsAspect: true, minSide: ItemHandles.shapeMinSide)
        case .line(let from, let to):
            return ItemHandles.Target(kind: .line, shape: .line(from: from, to: to), keepsAspect: false, minSide: 0)
        case .pen(let points):
            guard let first = points.first else { return nil }
            var minX = first.point.x, maxX = minX, minY = first.point.y, maxY = minY
            for p in points {
                minX = min(minX, p.point.x); maxX = max(maxX, p.point.x)
                minY = min(minY, p.point.y); maxY = max(maxY, p.point.y)
            }
            return ItemHandles.Target(kind: .pen, shape: .stroke(frame: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)), keepsAspect: false, minSide: 0)
        }
    }

    /// `index` の要素の形（と回転角）を `shape` にしたものを返す（色・太さ・塗りつぶしは、そのまま）。文字では、`fontSize` があれば、文字の大きさも変える。
    /// 要素の種類と形が合わないとき（ペンなど）は `nil`。
    func applying(_ shape: ItemHandles.Shape, fontSize: CGFloat? = nil, toItemAt index: Int) -> Document? {
        guard items.indices.contains(index) else { return nil }
        var copy = self
        switch (items[index].content, shape) {
        case (.image(let image, _), .box(let box, let angle)):
            copy.items[index].content = .image(image, box: box); copy.items[index].rotation = angle
        case (.ellipse, .box(let box, let angle)):
            copy.items[index].content = .ellipse(box); copy.items[index].rotation = angle
        case (.rect, .box(let box, let angle)):
            copy.items[index].content = .rect(box); copy.items[index].rotation = angle
        case (.text(let text, _), .box(let box, let angle)):
            copy.items[index].content = .text(text, box: box); copy.items[index].rotation = angle
            if let fontSize { copy.items[index].size = fontSize }
        case (.line, .line(let from, let to)):
            copy.items[index].content = .line(from: from, to: to)
        default: return nil
        }
        return copy
    }

    /// `index` の要素を、中心（直線は中点、ペンは点の外接する範囲の中心。そのほかは枠の中心）を軸に、`angle`（時計回りが正）だけ回したものを返す。
    /// 円・四角・画像・文字は、回転角を足す（元の枠は変えない）。直線・ペンは、点そのものを回す。範囲外なら `nil`。
    func rotating(itemAt index: Int, by angle: CGFloat) -> Document? {
        guard items.indices.contains(index), let target = resizeTarget(at: index) else { return nil }
        var copy = self
        let center = ItemHandles.center(of: target.shape)
        switch items[index].content {
        case .pen(let points):
            copy.items[index].content = .pen(points: points.map { StrokePoint(point: ItemHandles.rotate($0.point, about: center, by: angle), pressure: $0.pressure) })
        case .line(let from, let to):
            copy.items[index].content = .line(from: ItemHandles.rotate(from, about: center, by: angle), to: ItemHandles.rotate(to, about: center, by: angle))
        case .ellipse, .rect, .text, .image:
            copy.items[index].rotation = ItemHandles.normalized(items[index].rotation + angle)
        }
        return copy
    }

    /// 描いたもの（要素）をすべて消した文書を返す。背景画像は残す。消すものが無いときは `nil`（履歴に積む変更が無い）。
    func clearingItems() -> Document? {
        guard !items.isEmpty else { return nil }
        var copy = self
        copy.items = []
        return copy
    }

    /// `point` を囲む範囲を持つ、いちばん手前の要素の番号。無ければ `nil`。
    /// 円・四角・ペンの輪も、内側をクリックして掴める（囲む範囲で判定する）。
    func topItemIndex(at point: CGPoint, slop: CGFloat = Document.grabSlop) -> Int? {
        items.lastIndex { $0.bounds.insetBy(dx: -slop, dy: -slop).contains(point) }
    }
}
