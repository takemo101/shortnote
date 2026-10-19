import CoreGraphics

/// 手書きの線から見分けた、きれいな図形（SPEC §3.2.7）。回転は、ラジアン（時計回りが正。`Item.rotation` と同じ）。
enum RecognizedShape: Equatable {
    case line(from: CGPoint, to: CGPoint)
    /// 終点（`to`）に矢じりのある直線。
    case arrow(from: CGPoint, to: CGPoint)
    case ellipse(rect: CGRect, rotation: CGFloat)
    case rect(rect: CGRect, rotation: CGFloat)
    /// このアプリの三角形（二等辺三角形。頂点は、回す前の枠の上辺の中央）。
    case triangle(rect: CGRect, rotation: CGFloat)
}

extension RecognizedShape {
    /// 回すときの軸：円・四角・三角は、枠の中心。直線・矢印は、始点。
    var pivot: CGPoint {
        switch self {
        case .line(let from, _), .arrow(let from, _): return from
        case .ellipse(let rect, _), .rect(let rect, _), .triangle(let rect, _): return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// 軸のまわりに、`angle`（時計回りが正）だけ回した図形。直線・矢印は、終点が回る（長さは、変わらない）。
    func rotated(by angle: CGFloat) -> RecognizedShape {
        switch self {
        case .line(let from, let to): return .line(from: from, to: ItemHandles.rotate(to, about: from, by: angle))
        case .arrow(let from, let to): return .arrow(from: from, to: ItemHandles.rotate(to, about: from, by: angle))
        case .ellipse(let rect, let rotation): return .ellipse(rect: rect, rotation: ItemHandles.normalized(rotation + angle))
        case .rect(let rect, let rotation): return .rect(rect: rect, rotation: ItemHandles.normalized(rotation + angle))
        case .triangle(let rect, let rotation): return .triangle(rect: rect, rotation: ItemHandles.normalized(rotation + angle))
        }
    }

    /// 描いている線の色・太さを引き継いだ要素（塗りつぶしは、なし。矢印は、終点に矢じり）。
    func item(color: CGColor, size: CGFloat) -> Item {
        switch self {
        case .line(let from, let to): return Item(content: .line(from: from, to: to), color: color, size: size)
        case .arrow(let from, let to): return Item(content: .line(from: from, to: to), color: color, size: size, arrow: .end)
        case .ellipse(let rect, let rotation): return Item(content: .ellipse(rect), color: color, size: size, rotation: rotation)
        case .rect(let rect, let rotation): return Item(content: .rect(rect), color: color, size: size, rotation: rotation)
        case .triangle(let rect, let rotation): return Item(content: .triangle(rect), color: color, size: size, rotation: rotation)
        }
    }
}

/// 手書きの線（点の並び）が、円（楕円）・四角・三角・直線・矢印のどれかに見えるかを、点の並びだけで決める（学習モデルは使わない）。
enum ShapeRecognizer {
    /// これより短い線は、対象外（pt）。
    static let minLength: CGFloat = 30
    /// 始点と終点が、線全体の長さのこの割合より近ければ、閉じた線。
    static let closedRatio: CGFloat = 0.15
    /// 直線：すべての点が、始点〜終点の直線から、その長さのこの割合以内。
    static let lineDeviation: CGFloat = 0.08
    /// 閉じた図形：点から、図形の輪郭までの距離の二乗平均の平方根が、点の外接する範囲の対角線のこの割合以内。
    static let shapeError: CGFloat = 0.06
    /// 水平・垂直から、この角度（ラジアン。6°）以内なら、水平・垂直に直す。
    static let snapAngle: CGFloat = 6 * .pi / 180
    /// 縦横の短いほうが、長いほうのこの割合より小さい図形は、図形としない（行って戻っただけの線を、細い四角にしない）。
    static let minAspect: CGFloat = 0.15

    private static let sampleCount = 96

    static func recognize(_ input: [CGPoint]) -> RecognizedShape? {
        guard input.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let points = deduplicated(input)
        guard points.count >= 4 else { return nil }
        let length = pathLength(points)
        guard length >= minLength else { return nil }
        let samples = resampled(points, count: sampleCount)
        guard let first = samples.first, let last = samples.last else { return nil }
        if distance(first, last) < closedRatio * length { return closedShape(samples) }
        return openShape(samples, length: length)
    }

    // MARK: - 開いた線：直線・矢印

    private static func openShape(_ pts: [CGPoint], length: CGFloat) -> RecognizedShape? {
        let start = pts[0], end = pts[pts.count - 1]
        let chord = distance(start, end)
        if chord >= minLength, chord >= 0.9 * length,
           pts.allSatisfy({ distanceToLine($0, start, end) <= lineDeviation * chord }) {
            return .line(from: start, to: end)
        }
        // 矢印：始点から、いちばん遠い点（の 97% に、初めて届く点）が、矢じりの先。そこまでが、まっすぐな軸で、その先が、軸の向きへ折り返す短い線（矢じり）。
        // 先端には、2 度来る（2 本目の矢じりの前に、戻る）ので、最大の点ではなく、初めて届いた点にする
        let maxReach = pts.map { distance($0, start) }.max() ?? 0
        guard let tipIndex = pts.indices.first(where: { distance(pts[$0], start) >= 0.97 * maxReach }),
              tipIndex > 0, tipIndex < pts.count - 1 else { return nil }
        let tip = pts[tipIndex]
        let shaft = distance(start, tip)
        guard shaft >= minLength, shaft >= 0.5 * length else { return nil }
        guard pts[0...tipIndex].allSatisfy({ distanceToLine($0, start, tip) <= lineDeviation * shaft }) else { return nil }
        let tail = Array(pts[tipIndex...])
        guard let farthest = tail.max(by: { distance($0, tip) < distance($1, tip) }) else { return nil }
        let reach = distance(farthest, tip)
        guard reach >= 0.08 * shaft, reach <= 0.6 * shaft else { return nil }
        let back = CGPoint(x: (start.x - tip.x) / shaft, y: (start.y - tip.y) / shaft)
        let cosine = ((farthest.x - tip.x) * back.x + (farthest.y - tip.y) * back.y) / reach
        guard cosine >= 0.5 else { return nil }                                       // 軸の後ろ向き（60° 以内）へ折り返している
        guard tail.allSatisfy({ distance($0, tip) <= 0.6 * shaft }) else { return nil }
        return .arrow(from: start, to: tip)
    }

    // MARK: - 閉じた線：円・四角・三角

    private static func closedShape(_ pts: [CGPoint]) -> RecognizedShape? {
        let diagonal = boundsDiagonal(pts)
        guard diagonal > 0 else { return nil }
        var best: (shape: RecognizedShape, error: CGFloat)?
        func consider(_ candidate: (shape: RecognizedShape, polygon: [CGPoint])?) {
            guard let candidate else { return }
            let error = rootMeanSquare(pts.map { distanceToPolyline($0, candidate.polygon, closed: true) }) / diagonal
            if best == nil || error < best!.error { best = (candidate.shape, error) }
        }
        consider(bestBox(pts, ellipse: true))
        consider(bestBox(pts, ellipse: false))
        consider(triangle(pts, diagonal: diagonal))
        guard let best, best.error <= shapeError else { return nil }
        return best.shape
    }

    /// 回した枠（角度を、3° きざみで探し、さらに 0.5° きざみで直す。枠が、点を、いちばんきつく囲む向き）に、四角または楕円を、当てはめる。
    private static func bestBox(_ pts: [CGPoint], ellipse: Bool) -> (shape: RecognizedShape, polygon: [CGPoint])? {
        func tightest(_ angles: [CGFloat]) -> CGFloat? {
            var best: (angle: CGFloat, area: CGFloat)?
            for angle in angles {
                let extent = extents(pts, angle: angle)
                let area = extent.width * extent.height
                if best == nil || area < best!.area { best = (angle, area) }
            }
            return best?.angle
        }
        // -42°〜45°（90° ごとに同じ向き。縦横は、入れ替わりで表す）
        guard let coarse = tightest((-14...15).map { CGFloat($0) * 3 * .pi / 180 }),
              var angle = tightest((-6...6).map { coarse + CGFloat($0) * 0.5 * .pi / 180 }) else { return nil }
        var extent = extents(pts, angle: angle)
        // ほぼ円（縦横の差が 15% 以内）は、傾けない。水平・垂直に近い（6° 以内）なら、水平・垂直に直して、その向きで、枠を計り直す
        let aspect = min(extent.width, extent.height) / max(extent.width, extent.height)
        if abs(angle) <= snapAngle || (ellipse && aspect >= 0.85) { angle = 0; extent = extents(pts, angle: 0) }
        guard extent.width > 0, extent.height > 0, min(extent.width, extent.height) >= minAspect * max(extent.width, extent.height) else { return nil }
        if !ellipse, !cornersAreRight(pts) { return nil }   // 台形・平行四辺形を、四角にしない
        let rect = CGRect(x: extent.center.x - extent.width / 2, y: extent.center.y - extent.height / 2, width: extent.width, height: extent.height)
        let local = ellipse ? ellipsePolygon(width: extent.width, height: extent.height) : rectPolygon(width: extent.width, height: extent.height)
        let polygon = local.map { rotate($0, by: angle, about: .zero) + extent.center }
        return (ellipse ? .ellipse(rect: rect, rotation: angle) : .rect(rect: rect, rotation: angle), polygon)
    }

    /// 角が 4 つに単純にできる線は、その角が、ほぼ直角（62°〜118°）。角の数が 4 でない（丸い角など）ときは、確かめない。
    private static func cornersAreRight(_ pts: [CGPoint]) -> Bool {
        let corners = closedCorners(pts, epsilon: 0.07 * boundsDiagonal(pts))
        guard corners.count == 4 else { return true }
        for i in 0..<4 {
            let a = corners[(i + 3) % 4], b = corners[i], c = corners[(i + 1) % 4]
            let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let lengths = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
            guard lengths > 0 else { return false }
            let angle = acos(min(max((v1.x * v2.x + v1.y * v2.y) / lengths, -1), 1)) * 180 / .pi
            if angle < 62 || angle > 118 { return false }
        }
        return true
    }

    /// 二等辺三角形（このアプリの三角形）に、当てはめる。頂点は、点の並びを、3 つの角に、単純にしたもの。
    private static func triangle(_ pts: [CGPoint], diagonal: CGFloat) -> (shape: RecognizedShape, polygon: [CGPoint])? {
        var epsilon = 0.04 * diagonal
        var corners: [CGPoint] = []
        while epsilon < diagonal {
            corners = closedCorners(pts, epsilon: epsilon)
            if corners.count <= 3 { break }
            epsilon *= 1.25
        }
        guard corners.count == 3 else { return nil }
        // 頂点は、そこから出る 2 辺の長さが、いちばん近い角（残りの 2 つが底辺）。ほぼ同じ角が複数あるとき（正三角形に近い）は、
        // 底辺が、水平・垂直にいちばん近くなる（傾きが、90° の倍数にいちばん近い）ものにする
        let fits = (0..<3).compactMap { i -> (skew: CGFloat, rect: CGRect, theta: CGFloat)? in
            let apex = corners[i], b = corners[(i + 1) % 3], c = corners[(i + 2) % 3]
            guard let fit = triangleFit(apex: apex, b: b, c: c) else { return nil }
            return (abs(distance(apex, b) - distance(apex, c)), fit.rect, fit.theta)
        }
        guard let minSkew = fits.map(\.skew).min() else { return nil }
        let perimeter = distance(corners[0], corners[1]) + distance(corners[1], corners[2]) + distance(corners[2], corners[0])
        let quarter = CGFloat.pi / 2
        func tilt(_ theta: CGFloat) -> CGFloat { abs(theta - (theta / quarter).rounded() * quarter) + 0.01 * abs(theta) }
        guard let chosen = fits.filter({ $0.skew <= minSkew + 0.03 * perimeter }).min(by: { tilt($0.theta) < tilt($1.theta) }) else { return nil }
        var theta = chosen.theta
        // 90° の倍数に近ければ、そこに直す
        let nearest = (theta / quarter).rounded() * quarter
        if abs(theta - nearest) <= snapAngle { theta = normalized(nearest) }
        let rect = chosen.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let polygon = Triangle.points(in: rect).map { rotate($0, by: theta, about: center) }
        return (.triangle(rect: rect, rotation: theta), polygon)
    }

    /// `apex` を頂点、`b`〜`c` を底辺にした、このアプリの三角形の、枠（回す前）と、回転（頂点が、回した上側に来る向き）。
    private static func triangleFit(apex: CGPoint, b: CGPoint, c: CGPoint) -> (rect: CGRect, theta: CGFloat)? {
        let baseLength = distance(b, c)
        guard baseLength > 0 else { return nil }
        let middle = CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2)
        var theta = atan2(c.y - b.y, c.x - b.x)
        // 局所の下向き（回す前の `y`）は、(−sinθ, cosθ)。頂点は、その反対側（上）にある
        if (apex.x - middle.x) * -sin(theta) + (apex.y - middle.y) * cos(theta) > 0 { theta += .pi }
        theta = normalized(theta)
        let down = CGPoint(x: -sin(theta), y: cos(theta))
        let height = -((apex.x - middle.x) * down.x + (apex.y - middle.y) * down.y)
        guard height > 0, min(baseLength, height) >= minAspect * max(baseLength, height) else { return nil }
        let center = CGPoint(x: middle.x - down.x * height / 2, y: middle.y - down.y * height / 2)
        return (CGRect(x: center.x - baseLength / 2, y: center.y - height / 2, width: baseLength, height: height), theta)
    }

    /// 閉じた線の角（Douglas-Peucker）。重心からいちばん遠い点（たいてい、角）を始点にして、そこからいちばん遠い点で、2 つに分け、それぞれを単純にする
    /// （辺の途中から描き始めた線でも、本物の角が、始点の角に取り込まれないように）。
    private static func closedCorners(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let centroid = CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count), y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
        guard let startIndex = points.indices.max(by: { distance(points[$0], centroid) < distance(points[$1], centroid) }) else { return [] }
        let pts = Array(points[startIndex...]) + Array(points[..<startIndex])
        let origin = pts[0]
        guard let farIndex = pts.indices.max(by: { distance(pts[$0], origin) < distance(pts[$1], origin) }), farIndex > 0 else { return [] }
        let firstHalf = simplified(Array(pts[0...farIndex]), epsilon: epsilon)
        let secondHalf = simplified(Array(pts[farIndex...]) + [origin], epsilon: epsilon)
        var corners = firstHalf + secondHalf.dropFirst().dropLast()
        // 始点の近くの角を、まとめる（始点と終点が、少し離れていても、1 つの角にする）
        if corners.count > 3, let last = corners.last, distance(last, corners[0]) < 2 * epsilon { corners.removeLast() }
        return corners
    }

    private static func simplified(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let first = pts.first, let last = pts.last else { return pts }
        var worst = 0, worstDistance: CGFloat = 0
        for i in 1..<(pts.count - 1) {
            let d = distanceToSegment(pts[i], first, last)
            if d > worstDistance { worst = i; worstDistance = d }
        }
        guard worstDistance > epsilon else { return [first, last] }
        let left = simplified(Array(pts[0...worst]), epsilon: epsilon)
        let right = simplified(Array(pts[worst...]), epsilon: epsilon)
        return left + right.dropFirst()
    }

    // MARK: - 幾何

    /// 角度 `angle` の向きの枠で、点を囲んだときの、幅・高さ・中心（世界の座標）。
    private static func extents(_ pts: [CGPoint], angle: CGFloat) -> (width: CGFloat, height: CGFloat, center: CGPoint) {
        let c = cos(angle), s = sin(angle)
        var minU = CGFloat.infinity, maxU = -CGFloat.infinity, minV = CGFloat.infinity, maxV = -CGFloat.infinity
        for p in pts {
            let u = p.x * c + p.y * s, v = -p.x * s + p.y * c
            minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
        }
        let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
        return (maxU - minU, maxV - minV, CGPoint(x: cu * c - cv * s, y: cu * s + cv * c))
    }

    private static func rectPolygon(width: CGFloat, height: CGFloat) -> [CGPoint] {
        [CGPoint(x: -width / 2, y: -height / 2), CGPoint(x: width / 2, y: -height / 2), CGPoint(x: width / 2, y: height / 2), CGPoint(x: -width / 2, y: height / 2)]
    }

    private static func ellipsePolygon(width: CGFloat, height: CGFloat) -> [CGPoint] {
        EraserHit.ellipsePolygon(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), segments: 72)
    }

    private static func rotate(_ p: CGPoint, by angle: CGFloat, about center: CGPoint) -> CGPoint {
        ItemHandles.rotate(p, about: center, by: angle)
    }

    private static func normalized(_ angle: CGFloat) -> CGFloat { ItemHandles.normalized(angle) }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func distanceToLine(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let length = distance(a, b)
        guard length > 0 else { return distance(p, a) }
        return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        EraserHit.distance(from: p, toSegment: a, b)
    }

    private static func distanceToPolyline(_ p: CGPoint, _ polygon: [CGPoint], closed: Bool) -> CGFloat {
        EraserHit.distance(polyline: polygon, closed: closed, toSegment: p, p)
    }

    private static func rootMeanSquare(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return .infinity }
        return (values.reduce(0) { $0 + $1 * $1 } / CGFloat(values.count)).squareRoot()
    }

    private static func boundsDiagonal(_ pts: [CGPoint]) -> CGFloat {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return 0 }
        return hypot(maxX - minX, maxY - minY)
    }

    // MARK: - 点の並び

    /// ほぼ同じ位置（0.5 pt 未満）の連続した点を、まとめる。
    private static func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points where out.last.map({ distance($0, p) >= 0.5 }) ?? true { out.append(p) }
        return out
    }

    private static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        return (1..<pts.count).reduce(0) { $0 + distance(pts[$1 - 1], pts[$1]) }
    }

    /// 線の長さに沿って、等間隔に取り直した `count` 個の点（始点と終点を含む）。
    private static func resampled(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        let total = pathLength(pts)
        guard total > 0, count > 1 else { return pts }
        let step = total / CGFloat(count - 1)
        var out = [pts[0]]
        var travelled: CGFloat = 0, next = step
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let segment = distance(a, b)
            while segment > 0, travelled + segment >= next, out.count < count - 1 {
                let t = (next - travelled) / segment
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                next += step
            }
            travelled += segment
        }
        out.append(pts[pts.count - 1])
        return out
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
