import CoreGraphics

extension CGPoint {
    /// `rect` の範囲（縁を含む）に収めた点。範囲の中なら、そのまま。
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
