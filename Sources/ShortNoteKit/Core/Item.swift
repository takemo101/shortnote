import CoreGraphics

/// ペンの 1 点。筆圧は、タブレットのときだけ 1 未満になる。
struct StrokePoint {
    var point: CGPoint
    var pressure: CGFloat
}

/// キャンバスに取り込んだ画像。描画用の `CGImage` と、キャンバス上の自然な大きさ（ポイント）を持つ。
struct ImportedImage {
    let cgImage: CGImage
    let pointSize: CGSize
}

/// キャンバスに置く要素。種類ごとに必要な値だけを持つ（ペンに矩形がある、のような不正な組み合わせを作れない）。
/// 座標は、キャンバスの左上を原点とするポイント。
struct Item {
    enum Content {
        case pen(points: [StrokePoint])
        case line(from: CGPoint, to: CGPoint)
        case ellipse(CGRect)
        case rect(CGRect)
        case text(String, box: CGRect)
        case image(ImportedImage, box: CGRect)
    }

    var content: Content
    var color: CGColor
    /// ペンと図形では線の太さ、文字では文字の大きさ。画像では使わない。
    var size: CGFloat

    /// 要素を囲む範囲（移動ツールが掴める範囲）。線の太さの分だけ外側まで含める。
    var bounds: CGRect {
        switch content {
        case .line(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -size / 2, dy: -size / 2)
        case .pen(let points):
            guard let first = points.first else { return .zero }
            var minX = first.point.x, maxX = minX, minY = first.point.y, maxY = minY
            for p in points {
                minX = min(minX, p.point.x); maxX = max(maxX, p.point.x)
                minY = min(minY, p.point.y); maxY = max(maxY, p.point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -size / 2, dy: -size / 2)
        case .ellipse(let rect), .rect(let rect):
            return rect.insetBy(dx: -size / 2, dy: -size / 2)
        case .text(_, let box), .image(_, let box):
            return box
        }
    }

    /// 平行移動した要素を返す。
    func translated(by d: CGSize) -> Item {
        var item = self
        switch content {
        case .line(let a, let b):
            item.content = .line(from: CGPoint(x: a.x + d.width, y: a.y + d.height), to: CGPoint(x: b.x + d.width, y: b.y + d.height))
        case .pen(let points):
            item.content = .pen(points: points.map { StrokePoint(point: CGPoint(x: $0.point.x + d.width, y: $0.point.y + d.height), pressure: $0.pressure) })
        case .ellipse(let rect):
            item.content = .ellipse(rect.offsetBy(dx: d.width, dy: d.height))
        case .rect(let rect):
            item.content = .rect(rect.offsetBy(dx: d.width, dy: d.height))
        case .text(let text, let box):
            item.content = .text(text, box: box.offsetBy(dx: d.width, dy: d.height))
        case .image(let image, let box):
            item.content = .image(image, box: box.offsetBy(dx: d.width, dy: d.height))
        }
        return item
    }
}
