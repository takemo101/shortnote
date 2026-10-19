import CoreGraphics

/// ビュー：見えている範囲（SPEC §3.2.5）。画面だけの状態で、描いたもの・書き出し・履歴には影響しない。
/// 座標は、キャンバスの座標（左上が原点のポイント）。キャンバスは、ビューの大きさ（画面の大きさ）と同じ大きさで、原点は (0, 0)。
struct Viewport: Equatable {
    /// 倍率の範囲（25%〜400%）。
    static let zoomRange: ClosedRange<CGFloat> = 0.25...4
    /// キャンバスが、ビューから出てしまわないよう、画面で、これだけは見えている（pt）。
    static let minVisible: CGFloat = 64

    /// 倍率（画面の 1 pt が、キャンバスの `1 / zoom` pt）。
    var zoom: CGFloat = 1
    /// 見えている範囲の左上（キャンバスの座標）。
    var origin: CGPoint = .zero

    static let identity = Viewport()

    var isIdentity: Bool { self == .identity }

    /// 画面の 1 pt が、キャンバスの何 pt か。
    var scale: CGFloat { 1 / zoom }

    /// 見えている範囲（キャンバスの座標）。`viewSize` は、画面の大きさ（＝キャンバスの大きさ）。
    func visibleRect(viewSize: CGSize) -> CGRect {
        CGRect(origin: origin, size: CGSize(width: viewSize.width / zoom, height: viewSize.height / zoom))
    }

    /// 倍率と位置を、規則に収めたもの：倍率は `zoomRange`、キャンバス（`(0,0)`〜`viewSize`）は、各軸で、画面で `minVisible`（キャンバスの画面での大きさが、それより小さいときは、その大きさ）以上、見えている。
    /// 有限でない値は、等倍・動かしていない状態にする。
    func clamped(viewSize: CGSize) -> Viewport {
        guard zoom.isFinite, origin.x.isFinite, origin.y.isFinite, viewSize.width > 0, viewSize.height > 0 else { return .identity }
        var result = self
        result.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let visible = result.visibleRect(viewSize: viewSize)
        func axis(_ o: CGFloat, _ canvas: CGFloat, _ view: CGFloat) -> CGFloat {
            let m = min(Self.minVisible / result.zoom, canvas, view)   // キャンバスの座標での、見えているべき長さ
            return min(max(o, m - view), canvas - m)
        }
        result.origin = CGPoint(x: axis(origin.x, viewSize.width, visible.width), y: axis(origin.y, viewSize.height, visible.height))
        return result
    }

    /// 倍率を `factor` 倍にしたもの。`anchor`（キャンバスの座標）にある点は、画面の同じ位置に残る。
    func zoomed(by factor: CGFloat, anchor: CGPoint, viewSize: CGSize) -> Viewport {
        guard factor.isFinite, factor > 0 else { return clamped(viewSize: viewSize) }
        var next = self
        next.zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        next.origin = CGPoint(x: anchor.x - (anchor.x - origin.x) * zoom / next.zoom, y: anchor.y - (anchor.y - origin.y) * zoom / next.zoom)
        return next.clamped(viewSize: viewSize)
    }

    /// 画面で `delta`（右・下が正）だけ、内容が動くように、ビューを動かしたもの（見えている範囲は、逆向きに動く）。
    func panned(byScreen delta: CGSize, viewSize: CGSize) -> Viewport {
        var next = self
        next.origin = CGPoint(x: origin.x - delta.width / zoom, y: origin.y - delta.height / zoom)
        return next.clamped(viewSize: viewSize)
    }
}
