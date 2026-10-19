import Foundation

/// 設定画面でのグルーピング単位。
enum CommandGroup: CaseIterable {
    case window, edit, image, tool, view, brush
}

/// キーボードショートカットで呼び出せる操作。rawValue は永続化のキーなので変更しないこと。
enum Command: String, CaseIterable, Codable, Hashable {
    case showPanel, hidePanel
    case undo, redo, clearCanvas
    case pasteImage, openImage, copyPath
    case toolPen, toolLine, toolEllipse, toolRect, toolText, toolMove, toolTriangle, toolHand
    case viewReset
    case brushSmaller, brushLarger

    var title: String {
        switch self {
        case .showPanel: return "ウィンドウを出す（全域）"
        case .hidePanel: return "ウィンドウを隠す"
        case .undo: return "取り消し"
        case .redo: return "やり直し"
        case .clearCanvas: return "キャンバスをクリア"
        case .pasteImage: return "画像を貼り付け"
        case .openImage: return "画像ファイルを選ぶ"
        case .copyPath: return "パスをコピー"
        case .toolPen: return "ツール: ペン"
        case .toolEllipse: return "ツール: 円"
        case .toolRect: return "ツール: 四角"
        case .toolText: return "ツール: 文字"
        case .toolMove: return "ツール: 移動"
        case .toolLine: return "ツール: 直線"
        case .toolTriangle: return "ツール: 三角"
        case .toolHand: return "ツール: ハンド"
        case .viewReset: return "ビューを等倍に戻す"
        case .brushSmaller: return "ブラシを細く"
        case .brushLarger: return "ブラシを太く"
        }
    }

    /// アプリが非アクティブでも反応するシステム全域ホットキーか。
    var isGlobal: Bool { self == .showPanel }

    var group: CommandGroup {
        switch self {
        case .showPanel, .hidePanel: return .window
        case .undo, .redo, .clearCanvas: return .edit
        case .pasteImage, .openImage, .copyPath: return .image
        case .toolPen, .toolEllipse, .toolRect, .toolText, .toolMove, .toolLine, .toolTriangle, .toolHand: return .tool
        case .viewReset: return .view
        case .brushSmaller, .brushLarger: return .brush
        }
    }
}
