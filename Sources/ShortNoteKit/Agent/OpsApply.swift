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
    /// ファイルから画像を読む（`ImageIntake` と同じ形式。PDF の最初のページを含む）。読めなければ `nil`。
    /// 普通のファイルだけを読む（名前つきパイプやデバイスを指されても、読み込みで固まらない。シンボリックリンクは、先を見る）。
    static let loadFromDisk: (String) -> ImportedImage? = { path in
        let url = URL(fileURLWithPath: path)   // `~` を展開する（読み込みと、同じパスを見る）
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        if case .success(let image) = ImageIntake.image(at: url) { return image }
        return nil
    }

    /// `canvas` はキャンバスのポイント数。画像のファイルを読む（読めなければ `io`）。
    static func items(from ops: [Op], canvas: CGSize, loadImage: (String) -> ImportedImage? = OpsApply.loadFromDisk) -> Result<OpsResult, AgentError> {
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

            case .line(let from, let to, let color, let size, let arrow):
                let a = clamp(from), b = clamp(to)
                guard (a == from && b == to) || hypot(b.x - a.x, b.y - a.y) >= 1 else { result.skipped.append(i); continue }
                result.items.append(Item(content: .line(from: a, to: b), color: color.cgColor, size: size, arrow: arrow))

            case .ellipse(let rect, let color, let size, let fill, let rotate), .rect(let rect, let color, let size, let fill, let rotate),
                 .triangle(let rect, let color, let size, let fill, let rotate):
                let c1 = CGPoint(x: rect.minX, y: rect.minY), c2 = CGPoint(x: rect.maxX, y: rect.maxY)
                let a = clamp(c1), b = clamp(c2)
                let moved = a != c1 || b != c2    // 丸めなかった図形は、そのまま（浮動小数の丸め誤差で、幅 1 が 0.9999… になるのを避ける）
                let box = moved ? CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y) : rect
                guard !moved || (box.width >= 1 && box.height >= 1) else { result.skipped.append(i); continue }
                let content: Item.Content
                switch op {
                case .ellipse: content = .ellipse(box)
                case .triangle: content = .triangle(box)
                default: content = .rect(box)
                }
                result.items.append(Item(content: content, color: color.cgColor, size: size, filled: fill, rotation: radians(rotate)))

            case .text(let text, let at, let color, let fontSize, let rotate):
                let origin = clamp(at)
                let size = CanvasRenderer.textSize(text, size: fontSize, color: color.cgColor)
                result.items.append(Item(content: .text(text, box: CGRect(origin: origin, size: size)), color: color.cgColor, size: fontSize, rotation: radians(rotate)))

            case .image(let path, let at, let width, let height, let rotate):
                guard let image = loadImage(path) else { return .failure(.io("画像を読めません：\(path)", op: i)) }
                let origin = clamp(at)
                let box = imageBox(natural: image.pointSize, at: origin, width: width, height: height, canvas: canvas)
                result.items.append(Item(content: .image(image, box: box), color: CGColor(gray: 0, alpha: 1), size: 0, rotation: radians(rotate)))
            }
        }
        return .success(result)
    }

    /// 操作の `rotate`（度。時計回りが正）を、要素の回転角（ラジアン。`(-π, π]`）にする。
    /// 度のまま、360 で割った余りにしてから、ラジアンにする（1e308 のような値で、途中で無限大にならないように）。
    static func radians(_ degrees: Double) -> CGFloat {
        ItemHandles.normalized(CGFloat(degrees.truncatingRemainder(dividingBy: 360)) * .pi / 180)
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
