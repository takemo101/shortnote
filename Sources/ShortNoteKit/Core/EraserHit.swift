import CoreGraphics

/// 消しゴム（SPEC §3.2.6）の当たり判定：ポインタの動き（線分）が、要素の「実際に描かれている形」に触れるか。
/// 移動ツールの、外接する範囲で掴む判定とは違い、枠だけの図形の内側の空白には、触れない。
enum EraserHit {
    /// 点 `p` から、線分 `a`〜`b` までの距離。
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 線分 `a`〜`b` と、線分 `c`〜`d` の距離（交わるときは 0）。
    static func distance(segment a: CGPoint, _ b: CGPoint, toSegment c: CGPoint, _ d: CGPoint) -> CGFloat {
        if segmentsCross(a, b, c, d) { return 0 }
        return min(distance(from: a, toSegment: c, d), distance(from: b, toSegment: c, d),
                   distance(from: c, toSegment: a, b), distance(from: d, toSegment: a, b))
    }

    private static func segmentsCross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// 折れ線（`closed` なら、終点から始点へも結ぶ）と、線分 `a`〜`b` の距離。点が 1 つなら、その点との距離。点が無ければ `.infinity`。
    static func distance(polyline points: [CGPoint], closed: Bool, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return distance(from: first, toSegment: a, b) }
        var best = CGFloat.infinity
        for i in 1..<points.count { best = min(best, distance(segment: points[i - 1], points[i], toSegment: a, b)) }
        if closed, let last = points.last { best = min(best, distance(segment: last, first, toSegment: a, b)) }
        return best
    }

    /// 円（楕円）の外形の近似（多角形）。
    static func ellipsePolygon(in rect: CGRect, segments: Int = 64) -> [CGPoint] {
        (0..<segments).map { i in
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(segments)
            return CGPoint(x: rect.midX + rect.width / 2 * cos(t), y: rect.midY + rect.height / 2 * sin(t))
        }
    }

    static func rectPolygon(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
}

extension Item {
    /// ポインタの動き（`from` から `to` への線分。押しただけなら、同じ点）が、この要素に触れるか。`radius` は、ポインタの半径（キャンバスの座標）。
    /// ペン・直線（矢じりを含む）：線の近く（線の太さの半分を含む）。円・四角・三角：枠の線の近く（塗りつぶしは、内側も）。文字・画像：外接する枠（回しているときは、回した向きの枠）。
    func isTouched(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Bool {
        let half = size / 2
        switch content {
        case .pen(let points):
            // 描かれる幅は、筆圧で変わる（`CanvasRenderer.drawStroke`：太さ × (0.25〜1)。線分は、両端の筆圧の平均）
            func halfWidth(_ pressure: CGFloat) -> CGFloat { size * (0.25 + 0.75 * min(max(pressure, 0), 1)) / 2 }
            guard let first = points.first else { return false }
            if points.count == 1 { return EraserHit.distance(from: first.point, toSegment: a, b) <= radius + halfWidth(first.pressure) }
            for i in 1..<points.count {
                let reach = radius + halfWidth((points[i - 1].pressure + points[i].pressure) / 2)
                if EraserHit.distance(segment: points[i - 1].point, points[i].point, toSegment: a, b) <= reach { return true }
            }
            return false
        case .line(let from, let to):
            var d = EraserHit.distance(segment: from, to, toSegment: a, b)
            for head in Arrowhead.segments(from: from, to: to, size: size, arrow: arrow) {
                d = min(d, EraserHit.distance(segment: head.tip, head.end, toSegment: a, b))
            }
            return d <= radius + half
        case .rect(let rect), .ellipse(let rect), .triangle(let rect), .text(_, box: let rect), .image(_, box: let rect):
            // 回した枠は、ポインタの動きを逆に回して、回る前の枠の上で調べる
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let p = ItemHandles.rotate(a, about: center, by: -rotation), q = ItemHandles.rotate(b, about: center, by: -rotation)
            switch content {
            case .rect:
                return outlineTouched(EraserHit.rectPolygon(rect), from: p, to: q, radius: radius + half)
            case .ellipse:
                return outlineTouched(EraserHit.ellipsePolygon(in: rect), from: p, to: q, radius: radius + half)
            case .triangle:
                return outlineTouched(Triangle.points(in: rect), from: p, to: q, radius: radius + half)
            default:   // 文字・画像：枠の中（線の太さは無い）
                return outlineTouched(EraserHit.rectPolygon(rect), from: p, to: q, radius: radius, filledOverride: true)
            }
        }
    }

    private func outlineTouched(_ polygon: [CGPoint], from p: CGPoint, to q: CGPoint, radius: CGFloat, filledOverride: Bool? = nil) -> Bool {
        if EraserHit.distance(polyline: polygon, closed: true, toSegment: p, q) <= radius { return true }
        guard filledOverride ?? filled else { return false }
        let path = CGMutablePath()
        path.addLines(between: polygon)
        path.closeSubpath()
        return path.contains(p) || path.contains(q)
    }
}
