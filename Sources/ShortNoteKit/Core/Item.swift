import CoreGraphics

/// ペンの 1 点。筆圧は、タブレットのときだけ 1 未満になる。
struct StrokePoint: Equatable {
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
        /// 二等辺三角形。頂点は上辺の中央、底辺は下辺（`CGRect` に内接。描く向きは、上が頂点）。
        case triangle(CGRect)
        case text(String, box: CGRect)
        case image(ImportedImage, box: CGRect)
    }

    var content: Content
    var color: CGColor
    /// ペンと図形では線の太さ、文字では文字の大きさ。画像では使わない。
    var size: CGFloat
    /// 円・四角・三角で、枠の内側を、色で塗りつぶすか。ほかの要素では使わない（`false`）。
    var filled = false
    /// 回転角（ラジアン。時計回りが正。`(-π, π]`）。枠の中心が軸。円・四角・三角・画像・文字だけが持つ（ペン・直線は、点そのものを回すので、常に 0）。
    var rotation: CGFloat = 0
    /// 直線の矢じり（`none`・`end`＝終点・`both`＝両端）。直線だけが持つ（ほかの要素では `none`）。SPEC §3.2.2。
    var arrow: Arrow = .none

    enum Arrow: String {
        case none, end, both
    }

    /// 要素を囲む範囲（移動ツールが掴める範囲）。線の太さの分だけ外側まで含める。回転しているときは、回したあとの外接する範囲（軸に平行な最小の四角）。
    var bounds: CGRect {
        let base = unrotatedBounds
        guard rotation != 0 else { return base }
        let center = CGPoint(x: base.midX, y: base.midY)
        let corners = [CGPoint(x: base.minX, y: base.minY), CGPoint(x: base.maxX, y: base.minY),
                       CGPoint(x: base.minX, y: base.maxY), CGPoint(x: base.maxX, y: base.maxY)]
            .map { ItemHandles.rotate($0, about: center, by: rotation) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// 回転する前の `bounds`（描くときに、回した座標系の中で使う）。
    var unrotatedBounds: CGRect {
        switch content {
        case .line(let a, let b):
            let ends = [a, b] + Arrowhead.segments(from: a, to: b, size: size, arrow: arrow).map(\.end)   // 矢じりの先まで含める
            let xs = ends.map(\.x), ys = ends.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -size / 2, dy: -size / 2)
        case .pen(let points):
            guard let first = points.first else { return .zero }
            var minX = first.point.x, maxX = minX, minY = first.point.y, maxY = minY
            for p in points {
                minX = min(minX, p.point.x); maxX = max(maxX, p.point.x)
                minY = min(minY, p.point.y); maxY = max(maxY, p.point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -size / 2, dy: -size / 2)
        case .ellipse(let rect), .rect(let rect), .triangle(let rect):
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
        case .triangle(let rect):
            item.content = .triangle(rect.offsetBy(dx: d.width, dy: d.height))
        case .text(let text, let box):
            item.content = .text(text, box: box.offsetBy(dx: d.width, dy: d.height))
        case .image(let image, let box):
            item.content = .image(image, box: box.offsetBy(dx: d.width, dy: d.height))
        }
        return item
    }

    /// 形と回転角が同じか（移動・大きさの変更・回転で、変わったかの判定に使う。180° の回転のように、外接する範囲が変わらない変更も見分ける）。
    func hasSameGeometry(as other: Item) -> Bool {
        guard rotation == other.rotation, size == other.size else { return false }
        switch (content, other.content) {
        case (.pen(let a), .pen(let b)): return a == b
        case (.line(let a1, let a2), .line(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.ellipse(let a), .ellipse(let b)), (.rect(let a), .rect(let b)), (.triangle(let a), .triangle(let b)): return a == b
        case (.text(let s, let a), .text(let t, let b)): return s == t && a == b
        case (.image(_, let a), .image(_, let b)): return a == b
        default: return false
        }
    }
}
