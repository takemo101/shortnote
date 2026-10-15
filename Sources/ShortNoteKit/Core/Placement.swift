import CoreGraphics

/// 画像を置く枠の求め方。キャンバスで画像を開くときと、CLI の `render` で、同じ規則を使う。
enum Placement {
    /// `size` の画像を、`canvas` に収まるよう（拡大はせず）縮小して、中央に置いた枠。
    static func fitted(_ size: CGSize, in canvas: CGSize) -> CGRect {
        let scale = min(canvas.width / size.width, canvas.height / size.height, 1)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }
}
