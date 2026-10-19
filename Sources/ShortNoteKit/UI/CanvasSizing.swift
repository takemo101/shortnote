import AppKit

/// パネルの大きさと、キャンバスの大きさ（書き出すピクセル数）の対応。検証済みの `CanvasSize` を、ウィンドウに反映する。
final class CanvasSizing {
    private let panel: NSPanel
    private let canvas: CanvasView

    init(panel: NSPanel, canvas: CanvasView) {
        self.panel = panel
        self.canvas = canvas
    }

    private var screenFrame: CGRect { (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    /// この画面で取れる最大のキャンバス。画面の表示領域から、ウィンドウの枠（ツールバーなど）を引いて求める。
    var limits: CanvasSize.Limits {
        panel.contentView?.layoutSubtreeIfNeeded()
        let chromeW = panel.frame.width - canvas.canvasSize.width, chromeH = panel.frame.height - canvas.canvasSize.height
        return CanvasSize.Limits(availablePoints: CGSize(width: screenFrame.width - chromeW, height: screenFrame.height - chromeH))
    }

    /// ウィンドウを、キャンバスがちょうど `size` になる大きさにする（左上を動かさず、画面からはみ出す分は寄せる）。
    func apply(_ size: CanvasSize) {
        let target = size.points
        let current = canvas.canvasSize
        let old = panel.frame
        let frameSize = CGSize(width: old.width + target.width - current.width, height: old.height + target.height - current.height)
        let screen = screenFrame
        var origin = CGPoint(x: old.minX, y: old.maxY - frameSize.height)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - frameSize.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - frameSize.height)
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true, animate: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
}

/// キャンバスのサイズに関するダイアログ。何が悪かったかは `CanvasSize.Error` が決め、ここでは文にするだけ。
enum CanvasSizeDialog {
    static func showError(_ error: CanvasSize.Error, limits: CanvasSize.Limits) {
        let reason: String
        switch error {
        case .belowMinimum: reason = "小さすぎます。"
        case .notEven: reason = "幅と高さは偶数にしてください（画面では 2 ピクセルが 1 ポイントのため）。"
        case .exceedsLimits: reason = "この画面には大きすぎます。"
        }
        let alert = NSAlert()
        alert.messageText = "このサイズにはできません"
        alert.informativeText = "\(reason)キャンバスは 最小 \(CanvasSize.minimum.width) × \(CanvasSize.minimum.height) から、この画面では 最大 \(limits.width) × \(limits.height) ピクセルまでです。"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 幅と高さを数値で入力させる。取り消しなら `nil`。数値として読めない入力はビープで知らせて `nil`。
    static func prompt(current: CanvasSize, limits: CanvasSize.Limits) -> (width: Int, height: Int)? {
        let widthField = NSTextField(string: "\(current.width)")
        let heightField = NSTextField(string: "\(current.height)")
        for field in [widthField, heightField] {
            field.alignment = .right
            field.setAccessibilityLabel(field === widthField ? "幅" : "高さ")
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        let row = NSStackView(views: [widthField, NSTextField(labelWithString: "×"), heightField, NSTextField(labelWithString: "ピクセル")])
        row.orientation = .horizontal
        row.spacing = 6
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 24)

        let alert = NSAlert()
        alert.messageText = "キャンバスのサイズ"
        alert.informativeText = "書き出す画像のピクセル数です（最小 \(CanvasSize.minimum.width) × \(CanvasSize.minimum.height)、この画面では最大 \(limits.width) × \(limits.height)）。次回の起動でも使います。"
        alert.accessoryView = row
        alert.addButton(withTitle: "設定")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let w = Int(widthField.stringValue.trimmingCharacters(in: .whitespaces)),
              let h = Int(heightField.stringValue.trimmingCharacters(in: .whitespaces)) else {
            NSSound.beep()
            return nil
        }
        return (w, h)
    }
}
