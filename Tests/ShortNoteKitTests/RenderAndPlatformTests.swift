import AppKit
import Foundation
import Testing
@testable import ShortNoteKit

private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

/// 上半分が赤、下半分が青の画像（見た目の上下で）。
private func twoToneImage(width: Int = 40, height: Int = 40) -> ImportedImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))                 // y が小さい側 = 見た目の下
    ctx.setFillColor(red)
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))        // 見た目の上
    return ImportedImage(cgImage: ctx.makeImage()!, pointSize: CGSize(width: width, height: height))
}

/// PNG の (x, y) のピクセル（左上原点、ピクセル単位）。
private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
}

@Suite struct CanvasRendererTests {
    private let canvas = CGSize(width: 480, height: 320)

    private func export(_ document: Document, size: CGSize? = nil, transparent: Bool = false) throws -> NSBitmapImageRep {
        let data = try #require(CanvasRenderer.pngData(document, size: size ?? canvas, transparent: transparent))
        return try #require(NSBitmapImageRep(data: data))
    }

    @Test func export_isTwiceTheCanvasInPixels() throws {
        let rep = try export(Document())
        #expect(rep.pixelsWide == 960)
        #expect(rep.pixelsHigh == 640)
    }

    @Test func export_scaleIsLoweredOnlyBeyondTheLongSideCap() throws {
        #expect(CanvasRenderer.exportScale(for: CGSize(width: 4096, height: 100)) == 2)
        #expect(CanvasRenderer.exportScale(for: CGSize(width: 5000, height: 100)) == CGFloat(CanvasSize.maxSide) / 5000)
        let rep = try export(Document(), size: CGSize(width: 5000, height: 100))
        #expect(rep.pixelsWide == CanvasSize.maxSide)
    }

    @Test func export_isOpaqueWhiteUnlessTransparent() throws {
        let opaque = pixel(try export(Document()), 5, 5)
        #expect(opaque.a > 0.99 && opaque.r > 0.99 && opaque.g > 0.99 && opaque.b > 0.99)
        let clear = pixel(try export(Document(), transparent: true), 5, 5)
        #expect(clear.a == 0)
    }

    @Test func export_putsTheTopLeftOfTheCanvasAtTheTopLeftOfThePng() throws {
        let stroke = Item(content: .pen(points: [StrokePoint(point: CGPoint(x: 20, y: 20), pressure: 1),
                                                 StrokePoint(point: CGPoint(x: 30, y: 20), pressure: 1)]), color: red, size: 12)
        let rep = try export(Document().appending(stroke))
        let top = pixel(rep, 50, 40)               // ポイント (25, 20) の 2 倍
        let bottom = pixel(rep, 50, 640 - 40)      // 上下が逆なら、ここが赤になる
        #expect(top.r > 0.9 && top.g < 0.4 && top.b < 0.1 && top.a > 0.99, "top=\(top)")   // sRGB の赤を deviceRGB で読むと g が 0.25 ほどになる
        #expect(bottom.r > 0.99 && bottom.g > 0.99 && bottom.b > 0.99)
    }

    @Test func export_drawsAnImageTheRightWayUp() throws {
        let doc = Document(background: twoToneImage(), backgroundRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let rep = try export(doc)
        let upper = pixel(rep, 100, 40)    // 画像の上半分（ポイント y=20）
        let lower = pixel(rep, 100, 160)   // 画像の下半分（ポイント y=80）
        #expect(upper.r > 0.9 && upper.b < 0.1)
        #expect(lower.b > 0.9 && lower.r < 0.1)
    }

    @Test func export_keepsItemsInTheirStackingOrder() throws {
        func box(_ color: CGColor) -> Item { Item(content: .image(twoToneImage(), box: CGRect(x: 0, y: 0, width: 10, height: 10)), color: color, size: 0) }
        let stroke = Item(content: .pen(points: [StrokePoint(point: CGPoint(x: 5, y: 5), pressure: 1)]), color: CGColor(red: 0, green: 1, blue: 0, alpha: 1), size: 40)
        let rep = try export(Document().appending(box(red)).appending(stroke))   // 線は画像より手前
        let p = pixel(rep, 10, 10)
        #expect(p.g > 0.9 && p.r < 0.1)
    }

    @Test func export_failsForAnEmptyCanvas() {
        #expect(CanvasRenderer.pngData(Document(), size: .zero, transparent: false) == nil)
    }
}

@Suite struct ExportStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shortnote-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func url_reusesTheLastFileUntilInvalidated() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExportStore(directory: dir)
        var renders = 0
        let render: () -> Data? = { renders += 1; return Data([1, 2, 3]) }

        let first = try store.url(render: render).get()
        let again = try store.url(render: render).get()
        #expect(first == again)
        #expect(renders == 1)
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))

        store.invalidate()
        _ = try store.url(render: render).get()
        #expect(renders == 2)
    }

    @Test func url_writesANewFileWhenTheCachedOneWasDeleted() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExportStore(directory: dir)
        var renders = 0
        let first = try store.url(render: { renders += 1; return Data([9]) }).get()
        try FileManager.default.removeItem(at: first)
        let second = try store.url(render: { renders += 1; return Data([9]) }).get()
        #expect(renders == 2)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func url_reportsARenderFailure() {
        let dir = makeDirectory()
        let result = ExportStore(directory: dir).url(render: { nil })
        guard case .failure(.renderFailed) = result else { Issue.record("expected renderFailed, got \(result)"); return }
    }

    @Test func url_reportsAWriteFailure() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("file")
        try Data().write(to: blocker)
        // ファイルの下にはディレクトリを作れない。
        let result = ExportStore(directory: blocker.appendingPathComponent("sub")).url(render: { Data([1]) })
        guard case .failure(.writeFailed) = result else { Issue.record("expected writeFailed, got \(result)"); return }
    }
}

@Suite struct ImageIntakeTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shortnote-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(to url: URL, width: Int = 20, height: Int = 10) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    @Test func images_readsAPngWithItsPointSize() throws {
        let dir = try makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try writePNG(to: url, width: 20, height: 10)
        let images = try ImageIntake.images(at: [url]).get()
        #expect(images.count == 1)
        #expect(images[0].pointSize.width > 0 && images[0].pointSize.height > 0)
        #expect(images[0].cgImage.width == 20 && images[0].cgImage.height == 10)
    }

    @Test func images_ignoresFilesThatAreNotImages() throws {
        let dir = try makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("note.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        #expect(!ImageIntake.isImageFile(text))
        guard case .failure(.noImage) = ImageIntake.images(at: [text]) else { Issue.record("expected noImage"); return }
    }

    @Test func images_keepsTheReadableOnesAmongBrokenFiles() throws {
        let dir = try makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.png"), broken = dir.appendingPathComponent("broken.png")
        try writePNG(to: good)
        try Data([0, 1, 2]).write(to: broken)   // 拡張子は画像だが、中身は画像ではない
        #expect(try ImageIntake.images(at: [broken, good]).get().count == 1)
    }
}
