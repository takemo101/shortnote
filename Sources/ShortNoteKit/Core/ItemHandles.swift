import CoreGraphics
import Foundation

/// 選ばれた要素の取っ手（大きさの取っ手・回転の取っ手）の、掴める範囲の判定と、ドラッグしたあとの形の計算（SPEC §3.2.3）。
/// 座標は、上が小さい向き（`NSView` の flipped と同じ）。角度は、ラジアン。**時計回り（画面の上で）が正**。
enum ItemHandles {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// 枠の中の、この角の位置（回転する前の枠）。
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

    /// 掴める取っ手。枠の形（画像・円・四角・文字）は角、直線は両端、回転の取っ手はどの要素にもある。
    enum Handle: Equatable {
        case corner(Corner)
        case lineStart, lineEnd
        case rotate
    }

    /// 要素の形。
    enum Shape: Equatable {
        /// 画像・円・四角・三角・文字：回転する前の枠と、枠の中心を軸にした回転角。
        case box(CGRect, rotation: CGFloat)
        case line(from: CGPoint, to: CGPoint)
        /// ペン：点の外接する範囲（大きさの取っ手は無い。回転の取っ手と点線の枠だけ）。
        case stroke(frame: CGRect)
    }

    enum Kind: Equatable {
        case image, ellipse, rect, triangle, text, line, pen
    }

    /// 取っ手を出す要素の、いまの形と、規則（要素の種類で決まる）。
    struct Target {
        let kind: Kind
        let shape: Shape
        /// 縦横比を保つのが既定か（画像・文字は保つ。円・四角は保たない）。Shift で逆になる（文字は、常に保つ）。
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
    /// 短い辺がこれ未満の枠には、大きさの取っ手を出さない（9 pt の取っ手が、要素を覆ってしまい、中を掴めなくなるため）。
    static let minSideForHandles: CGFloat = 4
    /// 回転の取っ手と、枠の辺（上辺の中央、または下辺の中央）との距離（pt）。
    static let rotationHandleDistance: CGFloat = 24
    /// 回転の取っ手は、キャンバスの縁から、これだけ内側に収まる位置に出す（pt）。収まらないときは、反対側（下）に出す。
    static let rotationHandleMargin: CGFloat = 8
    /// Shift で回すときの、きざみ（15°）。
    static let snapAngle: CGFloat = .pi / 12

    // MARK: - 角度と点

    /// `p` を、`center` を軸に、`angle`（時計回りが正）だけ回した点。
    static func rotate(_ p: CGPoint, about center: CGPoint, by angle: CGFloat) -> CGPoint {
        if angle == 0 { return p }
        let c = cos(angle), s = sin(angle)
        let dx = p.x - center.x, dy = p.y - center.y
        return CGPoint(x: center.x + c * dx - s * dy, y: center.y + s * dx + c * dy)
    }

    /// `(-π, π]` に収めた角度（-π のすぐ上の誤差は、π にする。丸め誤差で、180° が -180° と出ないように）。
    static func normalized(_ angle: CGFloat) -> CGFloat {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi } else if a <= -.pi + 1e-9 { a += 2 * .pi }
        return a
    }

    /// `center` から `p` へ向かう向きの角度（右が 0、時計回りが正）。
    static func angle(from center: CGPoint, to p: CGPoint) -> CGFloat {
        atan2(p.y - center.y, p.x - center.x)
    }

    /// `angle` を、`snapAngle` の倍数に丸めたもの。
    static func snapped(_ angle: CGFloat) -> CGFloat {
        (angle / snapAngle).rounded() * snapAngle
    }

    // MARK: - 形の情報

    /// 回転する前の枠（直線は、両端の外接する範囲）。
    static func frame(of shape: Shape) -> CGRect {
        switch shape {
        case .box(let box, _): return box
        case .stroke(let frame): return frame
        case .line(let a, let b): return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }

    /// 回転の軸（枠の中心。直線は中点）。
    static func center(of shape: Shape) -> CGPoint {
        let f = frame(of: shape)
        return CGPoint(x: f.midX, y: f.midY)
    }

    static func rotation(of shape: Shape) -> CGFloat {
        if case .box(_, let rotation) = shape { return rotation }
        return 0
    }

    /// 回転の取っ手の位置と、枠の辺のつなぎ目（線を引く側の端）。上辺の中央から `rotationHandleDistance` 上。
    /// そこが、キャンバスの縁から `rotationHandleMargin` 以内（または外）になるときは、下辺の中央から下。
    /// どちらも収まらなければ（枠が、キャンバスの高さに近いとき）、上の位置を、縁から `rotationHandleMargin` の内側へ寄せる（取っ手が、キャンバスの外へ出て、届かなくならないように）。
    static func rotationHandle(of shape: Shape, canvas: CGRect) -> (stem: CGPoint, handle: CGPoint) {
        let f = frame(of: shape), c = center(of: shape), angle = rotation(of: shape)
        func world(_ stem: CGPoint, _ handle: CGPoint) -> (stem: CGPoint, handle: CGPoint) {
            (rotate(stem, about: c, by: angle), rotate(handle, about: c, by: angle))
        }
        let up = world(CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.midX, y: f.minY - rotationHandleDistance))
        let safe = canvas.insetBy(dx: rotationHandleMargin, dy: rotationHandleMargin)
        if safe.contains(up.handle) { return up }
        let down = world(CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY + rotationHandleDistance))
        if safe.contains(down.handle) { return down }
        guard !safe.isNull, !safe.isEmpty else { return up }
        return (up.stem, CGPoint(x: min(max(up.handle.x, safe.minX), safe.maxX), y: min(max(up.handle.y, safe.minY), safe.maxY)))
    }

    /// `shape` の取っ手の一覧（回転の取っ手を含む）。
    static func handles(of shape: Shape) -> [Handle] {
        switch shape {
        case .box(let box, _): return (isTooSmallForHandles(box) ? [] : Corner.allCases.map { .corner($0) }) + [.rotate]
        case .line: return [.lineStart, .lineEnd, .rotate]
        case .stroke: return [.rotate]
        }
    }

    private static func isTooSmallForHandles(_ box: CGRect) -> Bool {
        min(box.width, box.height) < minSideForHandles
    }

    /// `handle` の位置（画面の上の）。`shape` に無い取っ手なら `nil`。
    static func point(of handle: Handle, in shape: Shape, canvas: CGRect) -> CGPoint? {
        if handle == .rotate { return rotationHandle(of: shape, canvas: canvas).handle }
        guard let p = gripPoint(of: handle, in: shape) else { return nil }
        return rotate(p, about: center(of: shape), by: rotation(of: shape))
    }

    /// 大きさの取っ手の位置（回転する前の枠の上の）。
    private static func gripPoint(of handle: Handle, in shape: Shape) -> CGPoint? {
        switch (handle, shape) {
        case (.corner(let c), .box(let box, _)): return c.point(in: box)
        case (.lineStart, .line(let from, _)): return from
        case (.lineEnd, .line(_, let to)): return to
        default: return nil
        }
    }

    // MARK: - 掴める範囲

    /// `shape` の取っ手のうち、`point`（画面の上の）が掴める範囲に入るもの。回転の取っ手が先。重なるときは、近いほう。
    /// 大きさの取っ手の範囲は、外側へは `handleGrab / 2`。内側へ（枠は、その辺の中へ。直線は、もう一方の端へ向かって）は、同じ長さを、
    /// 要素が小さいとき、辺の長さ（直線は長さ）の 1/4 までに狭める（小さい要素の中を、掴んで動かせるように）。
    static func handle(at point: CGPoint, in shape: Shape, canvas: CGRect) -> Handle? {
        let half = handleGrab / 2
        if distance(point, rotationHandle(of: shape, canvas: canvas).handle) <= half { return .rotate }
        let hits: [Handle]
        switch shape {
        case .stroke:
            return nil
        case .box(let box, let angle):
            guard !isTooSmallForHandles(box) else { return nil }
            let local = rotate(point, about: CGPoint(x: box.midX, y: box.midY), by: -angle)   // 回る前の枠の上で調べる
            let inX = min(half, box.width / 4), inY = min(half, box.height / 4)
            hits = Corner.allCases.filter { c in
                let p = c.point(in: box)
                let left = c == .topLeft || c == .bottomLeft
                let top = c == .topLeft || c == .topRight
                let dx = local.x - p.x, dy = local.y - p.y
                let okX = left ? (dx >= -half && dx <= inX) : (dx >= -inX && dx <= half)
                let okY = top ? (dy >= -half && dy <= inY) : (dy >= -inY && dy <= half)
                return okX && okY
            }.map { .corner($0) }
            return hits.min { a, b in
                distance(local, gripPoint(of: a, in: shape) ?? local) < distance(local, gripPoint(of: b, in: shape) ?? local)
            }
        case .line(let from, let to):
            let length = distance(from, to)
            guard length > 0 else { return nil }
            hits = [Handle.lineStart, .lineEnd].filter { h in
                guard let p = gripPoint(of: h, in: shape) else { return false }
                let q = h == .lineStart ? to : from   // もう一方の端
                let along = ((point.x - p.x) * (q.x - p.x) + (point.y - p.y) * (q.y - p.y)) / length   // もう一方の端へ向かう成分
                return distance(point, p) <= half && along <= min(half, length / 4)
            }
            return hits.min { a, b in
                distance(point, gripPoint(of: a, in: shape) ?? point) < distance(point, gripPoint(of: b, in: shape) ?? point)
            }
        }
    }

    // MARK: - 大きさの変更

    /// `original` の `handle`（角か、直線の端）を、`pointer`（画面の上の）までドラッグしたあとの形。掴んでいない側（反対側の角、反対の端）は動かさない。
    /// 取っ手が形に合わないとき、直線が `lineMinLength` 未満になるときは `nil`（呼び出し側は、直前の形のままにする）。
    /// - `keepAspect`: 枠の形で、縦横比を保つか。
    /// - ポインタが、掴んだ取っ手の位置のままなら、`original` をそのまま返す（誤差で、動いていない形が、動いたことにならないように）。
    static func resized(_ original: Shape, handle: Handle, pointer: CGPoint, keepAspect: Bool, minSide: CGFloat) -> Shape? {
        guard let grabbed = point(of: handle, in: original, canvas: .null), handle != .rotate else { return nil }
        if distance(pointer, grabbed) < 1e-6 { return original }
        switch (handle, original) {
        case (.corner(let corner), .box(let box, let angle)):
            return .box(self.box(original: box, rotation: angle, corner: corner, pointer: pointer, keepAspect: keepAspect, minSide: minSide), rotation: angle)
        case (.lineStart, .line(_, let to)):
            return distance(pointer, to) >= lineMinLength ? .line(from: pointer, to: to) : nil
        case (.lineEnd, .line(let from, _)):
            return distance(from, pointer) >= lineMinLength ? .line(from: from, to: pointer) : nil
        default:
            return nil
        }
    }

    /// `original`（回転角 `rotation`）の `corner` を、`pointer`（画面の上の）までドラッグしたあとの枠（回転角は同じ）。反対側の角は、画面の上で動かさない。
    /// - `keepAspect`: `true` なら、縦横比を保つ（ポインタに近いほうの、大きいほうの辺に合わせる）。
    /// - 短い辺は `minSide` を下回らない（元の短い辺が `minSide` 未満なら、元の短い辺。触っただけで跳ねないように）。
    ///   ポインタが反対側の角を越えたら、枠は反対向きに伸びる。
    static func box(original: CGRect, rotation: CGFloat = 0, corner: Corner, pointer: CGPoint, keepAspect: Bool, minSide: CGFloat = imageMinSide) -> CGRect {
        let c0 = CGPoint(x: original.midX, y: original.midY)
        let grabbedWorld = rotate(corner.point(in: original), about: c0, by: rotation)
        if distance(pointer, grabbedWorld) < 1e-6 { return original }
        let anchor = corner.opposite.point(in: original)
        let grabbed = corner.point(in: original)
        let p = rotate(pointer, about: c0, by: -rotation)   // 回る前の枠の上の点にして、計算する
        let floor = max(0, min(minSide, original.width, original.height))
        // 反対側へ越えたときの向き。ちょうど重なったときは、掴んだ角のある向き。
        let sx: CGFloat = p.x == anchor.x ? (grabbed.x >= anchor.x ? 1 : -1) : (p.x > anchor.x ? 1 : -1)
        let sy: CGFloat = p.y == anchor.y ? (grabbed.y >= anchor.y ? 1 : -1) : (p.y > anchor.y ? 1 : -1)
        let dx = abs(p.x - anchor.x)
        let dy = abs(p.y - anchor.y)

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
        let local = CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
        return keepingAnchor(local, anchor: anchor, rotation: rotation, anchorWorld: rotate(anchor, about: c0, by: rotation))
    }

    /// `corner` の反対側の角を固定したまま、大きさを `size` にした枠（元の向きに伸びる。回転角は同じ）。文字の大きさを変えたあとの、置き直しに使う。
    static func anchoredBox(original: CGRect, rotation: CGFloat = 0, corner: Corner, size: CGSize) -> CGRect {
        let c0 = CGPoint(x: original.midX, y: original.midY)
        let anchor = corner.opposite.point(in: original)
        let x: CGFloat, y: CGFloat
        switch corner {
        case .bottomRight: (x, y) = (anchor.x, anchor.y)                        // 反対側は、左上
        case .topLeft: (x, y) = (anchor.x - size.width, anchor.y - size.height) // 反対側は、右下
        case .topRight: (x, y) = (anchor.x, anchor.y - size.height)             // 反対側は、左下
        case .bottomLeft: (x, y) = (anchor.x - size.width, anchor.y)            // 反対側は、右上
        }
        let local = CGRect(x: x, y: y, width: size.width, height: size.height)
        return keepingAnchor(local, anchor: anchor, rotation: rotation, anchorWorld: rotate(anchor, about: c0, by: rotation))
    }

    /// 回転は枠の中心が軸なので、枠の大きさを変えると、固定したい角が、画面の上で動く。その分だけ、枠をずらす。
    private static func keepingAnchor(_ local: CGRect, anchor: CGPoint, rotation: CGFloat, anchorWorld: CGPoint) -> CGRect {
        if rotation == 0 { return local }
        let moved = rotate(anchor, about: CGPoint(x: local.midX, y: local.midY), by: rotation)
        return local.offsetBy(dx: anchorWorld.x - moved.x, dy: anchorWorld.y - moved.y)
    }

    /// 文字を、角の取っ手のドラッグで、等倍に大きくする（小さくする）。倍率は、反対側の角から、掴んだ角の向きへ測った、ポインタの位置
    /// （枠の向きに沿った、幅・高さのうち、大きいほうの倍率。反対側の角を越えたら 0 以下＝下限）。その倍率で、文字の大きさを変え（`fontRange` に収める）、
    /// その大きさで描いたときの大きさ（`measure`）の枠を、反対側の角が動かないよう置く。文字の大きさが変わらなければ、`original` のまま。
    static func scaledText(original: CGRect, rotation: CGFloat, corner: Corner, pointer: CGPoint, fontSize: CGFloat,
                           fontRange: ClosedRange<CGFloat>, measure: (CGFloat) -> CGSize) -> (box: CGRect, fontSize: CGFloat) {
        guard original.width > 0, original.height > 0 else { return (original, fontSize) }
        let c0 = CGPoint(x: original.midX, y: original.midY)
        let grabbed = corner.point(in: original), anchor = corner.opposite.point(in: original)
        if distance(pointer, rotate(grabbed, about: c0, by: rotation)) < 1e-6 { return (original, fontSize) }
        let p = rotate(pointer, about: c0, by: -rotation)
        let sx: CGFloat = grabbed.x >= anchor.x ? 1 : -1, sy: CGFloat = grabbed.y >= anchor.y ? 1 : -1
        let scale = max((p.x - anchor.x) * sx / original.width, (p.y - anchor.y) * sy / original.height, 0)
        let newSize = min(max(fontSize * scale, fontRange.lowerBound), fontRange.upperBound)
        if newSize == fontSize { return (original, fontSize) }
        return (anchoredBox(original: original, rotation: rotation, corner: corner, size: measure(newSize)), newSize)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
