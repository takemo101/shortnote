import CoreGraphics

/// 画像・円・四角の角の取っ手と、直線の端の取っ手をドラッグしたときの、新しい形の計算（SPEC §3.2.3）。
/// 座標は、上が小さい向き（`NSView` の flipped と同じ）。
enum ItemResize {
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

    /// 掴める取っ手。枠の形（画像・円・四角）は角、直線は両端。
    enum Handle: Equatable {
        case corner(Corner)
        case lineStart, lineEnd
    }

    /// 大きさを変えられる要素の形。
    enum Shape: Equatable {
        case box(CGRect)
        case line(from: CGPoint, to: CGPoint)
    }

    /// 大きさを変えられる要素の、いまの形と、規則（要素の種類で決まる）。
    struct Target {
        let shape: Shape
        /// 縦横比を保つのが既定か（画像は保つ。円・四角は保たない）。Shift で逆になる。
        let keepsAspect: Bool
        /// 枠の短い辺の下限（pt）。
        let minSide: CGFloat
    }

    /// 画像の短い辺の下限（pt）。
    static let imageMinSide: CGFloat = 8
    /// 円・四角の短い辺の下限（pt）。描くときに捨てる大きさ（1 pt 未満）と同じ。
    static let shapeMinSide: CGFloat = 1
    /// 直線の長さの下限（pt）。描くときに捨てる長さと同じ。
    static let lineMinLength: CGFloat = 1
    /// 取っ手の見た目の大きさ（一辺。pt）。
    static let handleSize: CGFloat = 9
    /// 取っ手を掴める範囲（取っ手を中心にした一辺。pt）。見た目より、少し広い。
    static let handleGrab: CGFloat = 14

    /// `shape` の取っ手の一覧。
    static func handles(of shape: Shape) -> [Handle] {
        switch shape {
        case .box(let box): return isTooSmallForHandles(box) ? [] : Corner.allCases.map { .corner($0) }
        case .line: return [.lineStart, .lineEnd]
        }
    }

    /// 短い辺がこれ未満の枠には、取っ手を出さない（9 pt の取っ手が、要素を覆ってしまい、中を掴めなくなるため）。
    static let minSideForHandles: CGFloat = 4

    private static func isTooSmallForHandles(_ box: CGRect) -> Bool {
        min(box.width, box.height) < minSideForHandles
    }

    /// `handle` の位置。`shape` に無い取っ手なら `nil`。
    static func point(of handle: Handle, in shape: Shape) -> CGPoint? {
        switch (handle, shape) {
        case (.corner(let c), .box(let box)): return c.point(in: box)
        case (.lineStart, .line(let from, _)): return from
        case (.lineEnd, .line(_, let to)): return to
        default: return nil
        }
    }

    /// `shape` の取っ手のうち、`point` が掴める範囲に入るもの。重なるときは、近いほう。
    /// 掴める範囲は、外側へは `handleGrab / 2`。内側へ（枠は、その辺の中へ。直線は、もう一方の端へ向かって）は、同じ長さを、
    /// 要素が小さいとき、辺の長さ（直線は長さ）の 1/4 までに狭める（小さい要素の中を、掴んで動かせるように）。
    static func handle(at point: CGPoint, in shape: Shape) -> Handle? {
        let half = handleGrab / 2
        let hits: [Handle]
        switch shape {
        case .box(let box):
            guard !isTooSmallForHandles(box) else { return nil }
            let inX = min(half, box.width / 4), inY = min(half, box.height / 4)
            hits = Corner.allCases.filter { c in
                let p = c.point(in: box)
                let left = c == .topLeft || c == .bottomLeft
                let top = c == .topLeft || c == .topRight
                let dx = point.x - p.x, dy = point.y - p.y
                let okX = left ? (dx >= -half && dx <= inX) : (dx >= -inX && dx <= half)
                let okY = top ? (dy >= -half && dy <= inY) : (dy >= -inY && dy <= half)
                return okX && okY
            }.map { .corner($0) }
        case .line(let from, let to):
            let length = distance(from, to)
            guard length > 0 else { return nil }
            hits = [Handle.lineStart, .lineEnd].filter { h in
                guard let p = Self.point(of: h, in: shape) else { return false }
                let q = h == .lineStart ? to : from   // もう一方の端
                let along = ((point.x - p.x) * (q.x - p.x) + (point.y - p.y) * (q.y - p.y)) / length   // もう一方の端へ向かう成分
                return distance(point, p) <= half && along <= min(half, length / 4)
            }
        }
        return hits.min { a, b in
            distance(point, self.point(of: a, in: shape) ?? point) < distance(point, self.point(of: b, in: shape) ?? point)
        }
    }

    /// `original` の `handle` を、`pointer` までドラッグしたあとの形。掴んでいない側（反対側の角、反対の端）は動かさない。
    /// 取っ手が形に合わないとき、直線が `lineMinLength` 未満になるときは `nil`（呼び出し側は、直前の形のままにする）。
    /// - `keepAspect`: 枠の形で、縦横比を保つか。
    /// - ポインタが、掴んだ取っ手の位置のままなら、`original` をそのまま返す（誤差で、動いていない形が、動いたことにならないように）。
    static func resized(_ original: Shape, handle: Handle, pointer: CGPoint, keepAspect: Bool, minSide: CGFloat) -> Shape? {
        guard let grabbed = point(of: handle, in: original) else { return nil }
        if distance(pointer, grabbed) < 1e-6 { return original }
        switch (handle, original) {
        case (.corner(let corner), .box(let box)):
            return .box(self.box(original: box, corner: corner, pointer: pointer, keepAspect: keepAspect, minSide: minSide))
        case (.lineStart, .line(_, let to)):
            return distance(pointer, to) >= lineMinLength ? .line(from: pointer, to: to) : nil
        case (.lineEnd, .line(let from, _)):
            return distance(from, pointer) >= lineMinLength ? .line(from: from, to: pointer) : nil
        default:
            return nil
        }
    }

    /// `original` の `corner` を、`pointer` までドラッグしたあとの枠。反対側の角は動かさない。
    /// - `keepAspect`: `true` なら、縦横比を保つ（ポインタに近いほうの、大きいほうの辺に合わせる）。
    /// - 短い辺は `minSide` を下回らない（元の短い辺が `minSide` 未満なら、元の短い辺。触っただけで跳ねないように）。
    ///   ポインタが反対側の角を越えたら、枠は反対向きに伸びる。
    static func box(original: CGRect, corner: Corner, pointer: CGPoint, keepAspect: Bool, minSide: CGFloat = imageMinSide) -> CGRect {
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
