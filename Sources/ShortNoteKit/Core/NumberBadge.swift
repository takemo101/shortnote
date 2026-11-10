import CoreGraphics

/// 番号の印（`Item.Content.number`。SPEC §3.2.8）の規則。数字は保存せず、並びから決める。
enum NumberBadge {
    /// 丸の直径の下限（pt）。
    static let minimumDiameter: CGFloat = 22
    /// 操作の JSON の `d` の範囲（pt）。
    static let diameterRange: ClosedRange<CGFloat> = 8...200

    /// 置くときの、丸の直径：キャンバスの短い辺の 1/24（22 pt 以上）。
    static func diameter(forCanvas size: CGSize) -> CGFloat {
        max(minimumDiameter, min(size.width, size.height) / 24)
    }

    /// 中心が `center` の、直径 `diameter` の丸の、外接する四角。
    static func box(center: CGPoint, diameter: CGFloat) -> CGRect {
        CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    /// 各要素の数字。番号の印は、重なり順（奥から）の順位（1 から）。ほかの要素は `nil`。
    static func numbers(in items: [Item]) -> [Int?] {
        var next = 1
        return items.map { item in
            guard case .number = item.content else { return nil }
            defer { next += 1 }
            return next
        }
    }

    /// 番号の印の数。
    static func count(in items: [Item]) -> Int {
        items.reduce(0) { total, item in
            if case .number = item.content { return total + 1 }
            return total
        }
    }

    /// 数字を暗い色で描くか（丸の色が、白に近いとき）。`red`・`green`・`blue` は 0〜1。
    static func usesDarkNumeral(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.8
    }
}
