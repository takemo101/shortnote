import CoreGraphics
import Foundation

/// 操作を、キャンバスの要素（`Item`）にした結果。
struct OpsResult {
    /// 足す要素（操作の順。足さなかった操作の分は無い）。
    var items: [Item]
    /// 座標を、キャンバスの縁に丸めた操作の番号（足さなかったものを含む）。
    var clamped: [Int]
    /// 丸めた結果、大きさがなくなって、足さなかった操作の番号。
    var skipped: [Int]
}


/// 検証済みの操作を、`Item` にする（SPEC §3.7）。範囲外の座標は、エラーにせず、縁に丸める。
enum OpsApply {
    /// `canvas` はキャンバスのポイント数。画像のファイルを読む（読めなければ `io`）。
    static func items(from ops: [Op], canvas: CGSize, loadImage: (String) -> ImportedImage? = { path in
        if case .success(let image) = ImageIntake.image(at: URL(fileURLWithPath: path)) { return image }
        return nil
    }) -> Result<OpsResult, AgentError> {
        let area = CGRect(origin: .zero, size: canvas)
        var result = OpsResult(items: [], clamped: [], skipped: [])

        for (i, op) in ops.enumerated() {
            func clamp(_ p: CGPoint) -> CGPoint {
                let c = p.clamped(to: area)
                if c != p, result.clamped.last != i { result.clamped.append(i) }
                return c
            }
            switch op {
            case .pen(let points, let color, let size):
                let moved = points.map(clamp)
                let strokes = moved.map { StrokePoint(point: $0, pressure: 1) }
                result.items.append(Item(content: .pen(points: strokes), color: color.cgColor, size: size))

            case .line(let from, let to, let color, let size):
                let a = clamp(from), b = clamp(to)
                guard hypot(b.x - a.x, b.y - a.y) >= 1 else { result.skipped.append(i); continue }
                result.items.append(Item(content: .line(from: a, to: b), color: color.cgColor, size: size))

            case .ellipse(let rect, let color, let size), .rect(let rect, let color, let size):
                let a = clamp(CGPoint(x: rect.minX, y: rect.minY)), b = clamp(CGPoint(x: rect.maxX, y: rect.maxY))
                let box = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                guard box.width >= 1, box.height >= 1 else { result.skipped.append(i); continue }
                if case .ellipse = op {
                    result.items.append(Item(content: .ellipse(box), color: color.cgColor, size: size))
                } else {
                    result.items.append(Item(content: .rect(box), color: color.cgColor, size: size))
                }

            case .text(let text, let at, let color, let fontSize):
                let origin = clamp(at)
                let size = CanvasRenderer.textSize(text, size: fontSize, color: color.cgColor)
                result.items.append(Item(content: .text(text, box: CGRect(origin: origin, size: size)), color: color.cgColor, size: fontSize))

            case .image(let path, let at, let width, let height):
                guard let image = loadImage(path) else { return .failure(.io("画像を読めません：\(path)", op: i)) }
                let origin = clamp(at)
                let box = imageBox(natural: image.pointSize, at: origin, width: width, height: height, canvas: canvas)
                result.items.append(Item(content: .image(image, box: box), color: CGColor(gray: 0, alpha: 1), size: 0))
            }
        }
        return .success(result)
    }

    /// 画像の枠。`w`・`h` を省くと自然な大きさ（キャンバスより大きければ、収まるよう縮小。拡大はしない）。
    /// 片方だけなら縦横比を保ち、両方なら、そのまま。
    static func imageBox(natural: CGSize, at origin: CGPoint, width: CGFloat?, height: CGFloat?, canvas: CGSize) -> CGRect {
        let size: CGSize
        switch (width, height) {
        case (let w?, let h?): size = CGSize(width: w, height: h)
        case (let w?, nil): size = CGSize(width: w, height: w * natural.height / natural.width)
        case (nil, let h?): size = CGSize(width: h * natural.width / natural.height, height: h)
        case (nil, nil):
            let scale = min(canvas.width / natural.width, canvas.height / natural.height, 1)
            size = CGSize(width: natural.width * scale, height: natural.height * scale)
        }
        return CGRect(origin: origin, size: size)
    }
}
