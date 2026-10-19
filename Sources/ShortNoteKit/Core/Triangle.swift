import CoreGraphics

/// 三角形（`Item.Content.triangle`）の形。外接する四角に内接する二等辺三角形で、頂点は上辺の中央、底辺は下辺（y が下向きの座標）。
enum Triangle {
    /// 頂点、右下、左下の順。
    static func points(in rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points(in: rect))
        path.closeSubpath()
        return path
    }
}
