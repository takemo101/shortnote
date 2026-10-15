import Foundation

enum ExportError: Error {
    /// PNG を生成できなかった（キャンバスの大きさが 0 など）。
    case renderFailed
    /// ファイルに書けなかった（ディスクの空き、権限など）。
    case writeFailed(URL, underlying: Error)
}

/// 書き出した PNG の置き場と、直前の書き出しの再利用。
/// 内容が変わらない間は、同じファイルを返す（パスのコピー・ドラッグのたびに増やさない）。
final class ExportStore {
    /// 書き出し先。アプリ固定で、削除しない（OS の再起動などで消える）。
    static let directory = URL(fileURLWithPath: "/tmp/shortnote", isDirectory: true)

    private let directory: URL
    private var cachedURL: URL?

    init(directory: URL = ExportStore.directory) {
        self.directory = directory
    }

    /// 書き出し結果が変わる操作のあとに呼ぶ。次の `url` は、新しいファイルに書き出す。
    func invalidate() {
        cachedURL = nil
    }

    /// 最新の PNG のファイル。変更が無ければ直前のファイル、あれば `render` で生成して書き出す。
    func url(render: () -> Data?) -> Result<URL, ExportError> {
        if let cachedURL, FileManager.default.fileExists(atPath: cachedURL.path) { return .success(cachedURL) }
        guard let data = render() else { return .failure(.renderFailed) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = directory.appendingPathComponent("note-\(formatter.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(.writeFailed(url, underlying: error))
        }
        cachedURL = url
        return .success(url)
    }
}
