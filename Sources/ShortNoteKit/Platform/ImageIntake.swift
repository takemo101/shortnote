import AppKit
import UniformTypeIdentifiers

enum ImageIntakeError: Error, Equatable {
    /// 画像として読めるものが無かった。
    case noImage
}

/// 外から入る画像（ペーストボード・ドロップ・ファイル選択・CLI）を、`ImportedImage` にする入口。
/// 取り込みの経路が違っても、目的は同じ（画像を `[ImportedImage]` にする）なので、ここに集める。
enum ImageIntake {
    /// ファイル URL があれば画像のものだけを採り、無ければ画像データを採る。
    /// ファイル URL があるのに画像でない場合は、ファイルのアイコン画像を拾わないよう、何も採らない。
    static func images(from pasteboard: NSPasteboard) -> Result<[ImportedImage], ImageIntakeError> {
        let urls = fileURLs(in: pasteboard)
        if !urls.isEmpty { return images(at: urls) }
        let images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).compactMap(imported)
        return images.isEmpty ? .failure(.noImage) : .success(images)
    }

    /// 画像ファイルだけを読む（読めないもの・画像でないものは捨てる）。
    static func images(at urls: [URL]) -> Result<[ImportedImage], ImageIntakeError> {
        let images = urls.filter(isImageFile).compactMap { NSImage(contentsOf: $0) }.compactMap(imported)
        return images.isEmpty ? .failure(.noImage) : .success(images)
    }

    /// 明示的に 1 つ指定された画像（CLI 引数・`open`）。ファイルの種類で絞らず、`NSImage` が読めるものを読む（PDF なども開ける）。
    /// 貼り付け・ドロップのように、無関係なファイルが混ざる経路ではないので、絞らない。
    static func image(at url: URL) -> Result<ImportedImage, ImageIntakeError> {
        guard let image = NSImage(contentsOf: url).flatMap(imported) else { return .failure(.noImage) }
        return .success(image)
    }

    /// ドラッグがキャンバスに落とせるか（落とす前の判定。画像を読み込まずに、型だけで見る）。
    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        let urls = fileURLs(in: pasteboard)
        if !urls.isEmpty { return urls.contains(where: isImageFile) }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// ファイルの種類（型）が画像なら画像。型が不明・汎用（拡張子が無い・合わないファイルは `public.data` などになる）のときは、
    /// 後段で実際に画像として読めるかで判断する。画像以外の型（テキストなど）は受け付けない。
    static func isImageFile(_ url: URL) -> Bool {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            return type.conforms(to: .image) || type == .data || type.isDynamic
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// `NSImage` を、描画用の `CGImage` とポイント単位の大きさにする。大きさが 0 のもの・`CGImage` にできないものは捨てる。
    private static func imported(_ image: NSImage) -> ImportedImage? {
        guard image.isValid, image.size.width > 0, image.size.height > 0, let cg = cgImage(of: image) else { return nil }
        return ImportedImage(cgImage: cg, pointSize: image.size)
    }

    /// ビットマップの画像は、いちばん大きい表現の画素をそのまま使う（再描画で劣化させない。EXIF の向きは、表現の側で適用済み）。
    /// PDF などのベクター画像は、書き出しの倍率（`CanvasSize.exportScale`）の画素数に描く（画面の倍率に依らず、同じ結果にするため、
    /// `NSImage.cgImage(forProposedRect:)` は使わない）。
    private static func cgImage(of image: NSImage) -> CGImage? {
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let largest = bitmaps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return largest.cgImage
        }
        let scale = CGFloat(CanvasSize.exportScale)
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        return rep.cgImage
    }
}
