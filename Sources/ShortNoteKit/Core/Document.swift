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

    /// `index` の要素を、平行移動したものにして返す。範囲外なら `nil`。
    func translatingItem(at index: Int, by d: CGSize) -> Document? {
        guard items.indices.contains(index) else { return nil }
        var copy = self
        copy.items[index] = items[index].translated(by: d)
        return copy
    }

    /// `point` を囲む範囲を持つ、いちばん手前の要素の番号。無ければ `nil`。
    /// 円・四角・ペンの輪も、内側をクリックして掴める（囲む範囲で判定する）。
    func topItemIndex(at point: CGPoint, slop: CGFloat = 4) -> Int? {
        items.lastIndex { $0.bounds.insetBy(dx: -slop, dy: -slop).contains(point) }
    }
}
