import CoreGraphics

/// 画像の角の取っ手をドラッグしたときの、新しい枠の計算（SPEC §3.2.3）。座標は、上が小さい向き（`NSView` の flipped と同じ）。
enum ImageResize {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// 枠の中の、この角の位置。
        func point(in box: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: box.minX, y: box.minY)
            case .topRight: return CGPoint(x: box.maxX, y: box.minY)
            case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
            case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
            }
        }

        /// 反対側の角（ドラッグの間、動かさない角）。
        var opposite: Corner {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
            }
        }
    }

    /// 大きさの下限（短い辺。pt）。
    static let minSide: CGFloat = 8
    /// 取っ手の見た目の大きさ（一辺。pt）。
    static let handleSize: CGFloat = 9
    /// 取っ手を掴める範囲（角を中心にした一辺。pt）。見た目より、少し広い。
    static let handleGrab: CGFloat = 14

    /// `box` の角のうち、`point` が取っ手の掴める範囲に入る角。重なるときは、近いほう。
    /// 掴める範囲は、外側へは `handleGrab / 2`。内側へは、同じ長さを、辺の 1/4 までに狭める（小さい画像の中を、掴んで動かせるように）。
    static func corner(at point: CGPoint, in box: CGRect) -> Corner? {
        let half = handleGrab / 2
        let inX = min(half, box.width / 4), inY = min(half, box.height / 4)
        let hits = Corner.allCases.filter { c in
            let p = c.point(in: box)
            let left = c == .topLeft || c == .bottomLeft
            let top = c == .topLeft || c == .topRight
            let dx = point.x - p.x, dy = point.y - p.y
            let okX = left ? (dx >= -half && dx <= inX) : (dx >= -inX && dx <= half)
            let okY = top ? (dy >= -half && dy <= inY) : (dy >= -inY && dy <= half)
            return okX && okY
        }
        return hits.min { a, b in
            distance(point, a.point(in: box)) < distance(point, b.point(in: box))
        }
    }

    /// `original` の `corner` を、`pointer` までドラッグしたあとの枠。反対側の角は動かさない。
    /// - `keepAspect`: `true` なら、縦横比を保つ（ポインタに近いほうの、大きいほうの辺に合わせる）。
    /// - 短い辺は `minSide` を下回らない（元の短い辺が `minSide` 未満なら、元の短い辺。触っただけで跳ねないように）。
    ///   ポインタが反対側の角を越えたら、枠は反対向きに伸びる。
    /// - ポインタが、掴んだ角の位置のままなら、`original` をそのまま返す（誤差で、動いていない枠が、動いたことにならないように）。
    static func box(original: CGRect, corner: Corner, pointer: CGPoint, keepAspect: Bool) -> CGRect {
        let anchor = corner.opposite.point(in: original)
        let grabbed = corner.point(in: original)
        if distance(pointer, grabbed) < 1e-6 { return original }
        let floor = max(0, min(minSide, original.width, original.height))
        // 反対側へ越えたときの向き。ちょうど重なったときは、掴んだ角のある向き。
        let sx: CGFloat = pointer.x == anchor.x ? (grabbed.x >= anchor.x ? 1 : -1) : (pointer.x > anchor.x ? 1 : -1)
        let sy: CGFloat = pointer.y == anchor.y ? (grabbed.y >= anchor.y ? 1 : -1) : (pointer.y > anchor.y ? 1 : -1)
        let dx = abs(pointer.x - anchor.x)
        let dy = abs(pointer.y - anchor.y)

        var w: CGFloat
        var h: CGFloat
        if keepAspect, original.width > 0, original.height > 0 {
            let ratio = original.width / original.height
            w = max(dx, dy * ratio, floor, floor * ratio)   // 短い辺が下限に届く大きさ以上（縦横比は保つ）
            h = w / ratio
        } else {
            w = max(dx, floor)
            h = max(dy, floor)
        }
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
