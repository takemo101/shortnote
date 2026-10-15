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

    /// `index` の要素が、`base`（動かす前の文書）から動いているか。動かせる範囲の上限で止まって、動かなかったときは `false`。
    func hasMovedItem(at index: Int, since base: Document) -> Bool {
        guard items.indices.contains(index), base.items.indices.contains(index) else { return false }
        return items[index].bounds != base.items[index].bounds
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
