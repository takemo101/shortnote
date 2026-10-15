import AppKit

// ShortNote のアイコンを、コードで生成する（外部の素材は使わない）。
// 使い方（リポジトリのルートで）: ./scripts/make-icon.sh   （中で swift scripts/make-icon.swift <出力先> を実行する）
// 出力：
//   <出力先>/AppIcon.iconset/   … iconutil で AppIcon.icns にするための各サイズの PNG
//   <出力先>/MenuBarIcon.png    … メニューバー用の単色（テンプレート）画像。72×72 px（18 pt の 4 倍）
// 付箋（角が折れた黄色いメモ）に、手書きの線。

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output directory>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

/// `size` × `size` ピクセルの PNG を作る。`draw` は、`extent` × `extent` の座標系（左下原点）で描く。
func png(size: Int, extent: CGFloat, draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / extent, y: CGFloat(size) / extent)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
}

// MARK: - アプリのアイコン（1024 の座標系）

func drawAppIcon(_ ctx: CGContext) {
    // macOS のアイコンの形：1024 の中に、余白 100 を残した 824 の角丸の四角。
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 188, cornerHeight: 188, transform: nil)

    // 影つきで、下地を塗る。
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.38))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0xFFC83D))
    ctx.fillPath()
    ctx.restoreGState()

    // 付箋の黄色（上が明るく、下がやや濃い）。
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient(color(0xFFE680), color(0xFFC32E)), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // 上端に、細い光（紙の厚み）。
    ctx.setFillColor(color(0xFFFFFF, 0.28))
    ctx.fill(CGRect(x: 100, y: 884, width: 824, height: 40))
    ctx.restoreGState()

    // 右下の角を折る：角（三角形）を切り取り、折り返した部分（フラップ）を描く。
    let a = CGPoint(x: 704, y: 100), b = CGPoint(x: 924, y: 320)       // 切り口の両端
    let corner = CGPoint(x: 924, y: 100)
    let flapTip = CGPoint(x: 704, y: 320)                               // 角を、切り口で折り返した位置
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: corner); ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -6, height: 8), blur: 14, color: color(0x6B4A00, 0.45))
    ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: flapTip); ctx.closePath()
    ctx.clip()
    ctx.drawLinearGradient(gradient(color(0xFFF0B0), color(0xE9A400)), start: CGPoint(x: 880, y: 340), end: CGPoint(x: 704, y: 100), options: [])
    ctx.restoreGState()

    // 手書きの線（濃い紺のインク）。上に波の線、下に長短の 2 本の行。
    ctx.saveGState()
    ctx.setStrokeColor(color(0x26304F))
    ctx.setLineWidth(60)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 244, y: 690))
    wave.addCurve(to: CGPoint(x: 512, y: 690), control1: CGPoint(x: 316, y: 820), control2: CGPoint(x: 440, y: 820))
    wave.addCurve(to: CGPoint(x: 780, y: 690), control1: CGPoint(x: 584, y: 560), control2: CGPoint(x: 708, y: 560))
    ctx.addPath(wave)
    ctx.strokePath()
    let line1 = CGMutablePath()
    line1.move(to: CGPoint(x: 244, y: 500))
    line1.addCurve(to: CGPoint(x: 724, y: 504), control1: CGPoint(x: 380, y: 530), control2: CGPoint(x: 560, y: 470))
    ctx.addPath(line1)
    ctx.strokePath()
    let line2 = CGMutablePath()
    line2.move(to: CGPoint(x: 244, y: 350))
    line2.addCurve(to: CGPoint(x: 508, y: 354), control1: CGPoint(x: 330, y: 372), control2: CGPoint(x: 420, y: 330))
    ctx.addPath(line2)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - メニューバーのアイコン（18 の座標系。単色。透明部分が「抜き」になる）

func drawMenuBarIcon(_ ctx: CGContext) {
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    // 付箋の本体（角丸）。
    let body = CGPath(roundedRect: CGRect(x: 2.2, y: 1.8, width: 13.6, height: 14.4), cornerWidth: 2.8, cornerHeight: 2.8, transform: nil)
    ctx.addPath(body)
    ctx.fillPath()

    // 右下の角を折る：角を切り取り、折り返しは半透明で描く。
    let a = CGPoint(x: 10.0, y: 1.8), b = CGPoint(x: 15.8, y: 7.6), corner = CGPoint(x: 15.8, y: 1.8), tip = CGPoint(x: 10.0, y: 7.6)
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: corner); ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
    ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: tip); ctx.closePath()
    ctx.fillPath()

    // 手書きの線を、抜きにする。
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(1.7)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 4.6, y: 13.0))
    wave.addCurve(to: CGPoint(x: 9.0, y: 13.0), control1: CGPoint(x: 5.5, y: 14.8), control2: CGPoint(x: 7.7, y: 14.8))
    wave.addCurve(to: CGPoint(x: 13.4, y: 13.0), control1: CGPoint(x: 10.3, y: 11.2), control2: CGPoint(x: 12.5, y: 11.2))
    ctx.addPath(wave)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 4.6, y: 9.4))        // 長い行
    ctx.addLine(to: CGPoint(x: 12.6, y: 9.4))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 4.6, y: 5.9))        // 短い行（折り返しの左）
    ctx.addLine(to: CGPoint(x: 8.0, y: 5.9))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - 書き出し

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    try png(size: entry.pixels, extent: 1024, draw: drawAppIcon).write(to: iconset.appendingPathComponent("\(entry.name).png"))
}
try png(size: 72, extent: 18, draw: drawMenuBarIcon).write(to: outDir.appendingPathComponent("MenuBarIcon.png"))
print("wrote \(iconset.path) and MenuBarIcon.png")
