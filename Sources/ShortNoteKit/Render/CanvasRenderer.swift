import AppKit

/// キャンバスの描画と、PNG の書き出し。画面と書き出しは同じ `drawContent` を通す。
/// 座標は左上原点。文字の描画が現在の `NSGraphicsContext` を使うので、呼び出し側は、左上原点（反転済み）の
/// `NSGraphicsContext` を現在のものにして、同じ `CGContext` を渡すこと（`NSView.draw` の中、または `pngData`）。
enum CanvasRenderer {
    // MARK: - 画面と書き出しに共通

    /// 背景画像 → 確定済みの要素 → 描画中の要素の順に描く。`faded`（要素の番号）は、薄く描く（消しゴムの、消える印。画面だけ。SPEC §3.2.6）。
    static func drawContent(_ document: Document, draft: Item?, faded: Set<Int> = [], in ctx: CGContext) {
        if let background = document.background {
            drawImage(background, in: document.backgroundRect, ctx)
        }
        for (index, item) in document.items.enumerated() {
            if faded.contains(index) {
                ctx.saveGState()
                ctx.setAlpha(0.25)
                ctx.beginTransparencyLayer(in: item.bounds.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)   // 色の透明度・塗りの重なりを含めて、1 枚として薄くする。範囲は、要素の外接する範囲まで（キャンバス全体の大きさにすると、印の数だけ、大きなバッファを取り、遅い）
                draw(item, in: ctx)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            } else {
                draw(item, in: ctx)
            }
        }
        if let draft { draw(draft, in: ctx) }
    }

    /// 文字の見た目。入力欄と描画で同じものを使う。
    static func textAttributes(size: CGFloat, color: CGColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.black,
        ]
    }

    /// 文字を描いたときの大きさ（ポイント）。
    static func textSize(_ text: String, size: CGFloat, color: CGColor) -> CGSize {
        let box = NSAttributedString(string: text, attributes: textAttributes(size: size, color: color))
            .boundingRect(with: CGSize(width: 1e5, height: 1e5), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(box.width), height: ceil(box.height))
    }

    // MARK: - 画面だけ

    /// 画面の下地。背景透過がオンなら市松模様、オフなら白。書き出しには使わない（書き出しは透過なら何も敷かない）。
    static func drawBackdrop(transparent: Bool, bounds: CGRect, in ctx: CGContext) {
        guard transparent else {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(bounds)
            return
        }
        let tile: CGFloat = 8
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(bounds)
        ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
        var y: CGFloat = 0
        var row = 0
        while y < bounds.height {
            var x: CGFloat = row % 2 == 0 ? 0 : tile
            while x < bounds.width {
                ctx.fill(CGRect(x: x, y: y, width: tile, height: tile))
                x += tile * 2
            }
            y += tile
            row += 1
        }
    }

    // MARK: - 書き出し

    /// キャンバス全体を PNG にする。ピクセル数は、ポイント数の `CanvasSize.exportScale` 倍。
    /// 背景透過なら白地を敷かず、アルファ付きにする。長辺が `CanvasSize.maxSide` を超える巨大なキャンバスでだけ、倍率を下げる。
    /// 生成できなければ `nil`。
    static func pngData(_ document: Document, size: CGSize, transparent: Bool) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = exportScale(for: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        // ビットマップはピクセル座標で左下原点。画面と同じ「ポイント座標・左上原点」で描けるよう、
        // 上下を反転して倍率を掛け、反転済みのコンテキストとして渡す。
        let ctx = base.cgContext
        ctx.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        ctx.scaleBy(x: CGFloat(rep.pixelsWide) / size.width, y: -CGFloat(rep.pixelsHigh) / size.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        if !transparent {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        drawContent(document, draft: nil, in: ctx)
        return rep.representation(using: .png, properties: [:])
    }

    /// 書き出しの倍率。通常は `CanvasSize.exportScale`。
    static func exportScale(for size: CGSize) -> CGFloat {
        let scale = CGFloat(CanvasSize.exportScale)
        let longest = max(size.width, size.height)
        return longest > 0 ? min(scale, CGFloat(CanvasSize.maxSide) / longest) : scale
    }

    // MARK: - 要素

    private static func draw(_ item: Item, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(item.color)
        ctx.setFillColor(item.color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if item.rotation != 0 {   // 枠の中心を軸に回す（円・四角・画像・文字だけが、回転角を持つ）
            let box = item.unrotatedBounds
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: item.rotation)
            ctx.translateBy(x: -box.midX, y: -box.midY)
        }

        switch item.content {
        case .line(let a, let b):
            ctx.setLineWidth(item.size)
            ctx.move(to: a)
            ctx.addLine(to: b)
            for head in Arrowhead.segments(from: a, to: b, size: item.size, arrow: item.arrow) {   // 矢じり：端から外側へ、2 本の線
                ctx.move(to: head.tip)
                ctx.addLine(to: head.end)
            }
            ctx.strokePath()
        case .pen(let points):
            drawStroke(points, size: item.size, in: ctx)
        case .rect(let rect):
            if item.filled {
                drawFilled(item, in: ctx) { $0.addRect(rect) }
            } else {
                ctx.setLineWidth(item.size)
                ctx.stroke(rect)
            }
        case .triangle(let rect):
            if item.filled {
                drawFilled(item, in: ctx) { $0.addPath(Triangle.path(in: rect)) }
            } else {
                ctx.setLineWidth(item.size)
                ctx.addPath(Triangle.path(in: rect))
                ctx.strokePath()
            }
        case .ellipse(let rect):
            if item.filled {
                drawFilled(item, in: ctx) { $0.addEllipse(in: rect) }
            } else {
                ctx.setLineWidth(item.size)
                ctx.strokeEllipse(in: rect)
            }
        case .text(let text, let box):
            NSAttributedString(string: text, attributes: textAttributes(size: item.size, color: item.color))
                .draw(with: box, options: [.usesLineFragmentOrigin])
        case .image(let image, let box):
            drawImage(image, in: box, ctx)
        }
    }

    /// 塗りつぶした図形：枠と同じ外形（線の太さを含む）の内側を、色で塗る。枠の線も、同じ色で引く（外形に溶ける）。
    /// 透明度のある色でも、塗りと線の重なりが濃くならないよう、不透明な色で描いた 1 枚を、透明度つきで重ねる。
    /// 1 枚の大きさは、図形の外接する範囲まで（キャンバス全体の大きさにすると、図形の数だけ、大きなバッファを取り、遅い）。
    private static func drawFilled(_ item: Item, in ctx: CGContext, path: (CGContext) -> Void) {
        let opaque = item.color.copy(alpha: 1) ?? item.color
        ctx.setAlpha(item.color.alpha)
        ctx.beginTransparencyLayer(in: item.unrotatedBounds.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil)   // 回した座標系の中の範囲
        ctx.setFillColor(opaque)
        ctx.setStrokeColor(opaque)
        ctx.setLineWidth(item.size)
        path(ctx)
        ctx.drawPath(using: .fillStroke)
        ctx.endTransparencyLayer()
    }

    /// 筆圧に応じて太さを変えながら、点をつないで描く。点が 1 つなら丸を打つ。
    private static func drawStroke(_ points: [StrokePoint], size: CGFloat, in ctx: CGContext) {
        func width(_ pressure: CGFloat) -> CGFloat { size * (0.25 + 0.75 * min(max(pressure, 0), 1)) }
        if points.count == 1, let p = points.first {
            let w = width(p.pressure)
            ctx.fillEllipse(in: CGRect(x: p.point.x - w / 2, y: p.point.y - w / 2, width: w, height: w))
        } else if points.count > 1 {
            for i in 1..<points.count {
                ctx.setLineWidth(width((points[i - 1].pressure + points[i].pressure) / 2))
                ctx.move(to: points[i - 1].point)
                ctx.addLine(to: points[i].point)
                ctx.strokePath()
            }
        }
    }

    /// 左上原点（y が下向き）のコンテキストに、画像を正しい向きで描く（`CGContext.draw` は y が上向きを前提にするため、その場で反転する）。
    private static func drawImage(_ image: ImportedImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image.cgImage, in: CGRect(origin: .zero, size: rect.size))
    }
}
