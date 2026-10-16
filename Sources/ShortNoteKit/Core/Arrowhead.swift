import CoreGraphics

/// 直線の矢じりの形（SPEC §3.2.2）。端から、線の反対向きへ、左右に `spread` ずつ開いた 2 本の短い線。
enum Arrowhead {
    /// 矢じりの開き（片側。ラジアン。28°）。
    static let spread: CGFloat = 28 * .pi / 180

    /// 矢じりの 1 本の長さ。`10 + 太さ × 2.5` pt。直線の長さの 2/3 を超えるときは、その長さ。
    static func length(size: CGFloat, lineLength: CGFloat) -> CGFloat {
        min(10 + size * 2.5, lineLength * 2 / 3)
    }

    /// `tip`（端）にある矢じりの、2 本の線の、外側の端点。`other` は、直線のもう一方の端（線の向きを決める）。
    /// 長さのない直線（`tip == other`）には、矢じりがない（空）。
    static func arms(tip: CGPoint, other: CGPoint, size: CGFloat) -> [CGPoint] {
        let dx = other.x - tip.x, dy = other.y - tip.y
        let lineLength = hypot(dx, dy)
        guard lineLength > 0 else { return [] }
        let length = Self.length(size: size, lineLength: lineLength)
        let u = CGPoint(x: dx / lineLength, y: dy / lineLength)   // 端から、もう一方の端へ向かう向き
        return [spread, -spread].map { angle in
            let c = cos(angle), s = sin(angle)
            return CGPoint(x: tip.x + length * (c * u.x - s * u.y), y: tip.y + length * (s * u.x + c * u.y))
        }
    }

    /// 矢じりの、線（端 → 外側の端点）の一覧。
    static func segments(from: CGPoint, to: CGPoint, size: CGFloat, arrow: Item.Arrow) -> [(tip: CGPoint, end: CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        if arrow == .end || arrow == .both { out += arms(tip: to, other: from, size: size).map { (to, $0) } }
        if arrow == .both { out += arms(tip: from, other: to, size: size).map { (from, $0) } }
        return out
    }
}
