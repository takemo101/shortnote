import AppKit
import Testing
@testable import ShortNoteKit

@Suite("パレットのボタン：ふつうの操作ボタンは、押しても「選び」にならない")
@MainActor
struct PaletteButtonTests {
    private final class Counter: NSObject {
        var count = 0
        @objc func hit() { count += 1 }
    }

    @Test("押す・アクセシビリティの「押す」で、操作は届き、選び（isOn）にはならない（標準のボタンは、押すたびに state を入れ替えるので、アクセントの面が残っていた）")
    func actionButtonNeverBecomesSelected() {
        _ = NSApplication.shared   // `performClick` は、アプリのオブジェクトを通す
        let counter = Counter()
        let button = PaletteButton(symbol: "doc.on.doc", label: "テスト", role: .button)
        button.target = counter
        button.action = #selector(Counter.hit)

        button.performClick(nil)
        #expect(counter.count == 1 && !button.isOn)
        button.performClick(nil)
        #expect(counter.count == 2 && !button.isOn)
        // アクセシビリティの「押す」は、窓の中のボタンで試す
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(button)
        let pressed = button.accessibilityPerformPress()
        #expect(!button.isOn)
        if pressed { #expect(counter.count == 3) }
    }

    @Test("明示的に選びにした状態（メニューの印）は、押しても、そのまま（押しても、選びが外れない）")
    func explicitSelectionIsKept() {
        _ = NSApplication.shared
        let counter = Counter()
        let cell = PaletteButton(symbol: nil, label: "マス", role: .button)
        cell.target = counter
        cell.action = #selector(Counter.hit)
        cell.isOn = true
        cell.performClick(nil)
        #expect(counter.count == 1 && cell.isOn)
    }

    @Test("ラジオ（ツールのボタン）・チェックボックスは、これまでどおり、標準の状態の入れ替えに従う設定のまま（操作ボタンだけ、入れ替えを止める）")
    func onlyActionButtonsKeepState() {
        for role in [PaletteButton.Role.radio, .checkbox] {
            let button = PaletteButton(symbol: nil, label: "x", role: role)
            #expect((button.cell as? PaletteButtonCell)?.keepsState == false)
        }
        #expect((PaletteButton(symbol: nil, label: "x", role: .button).cell as? PaletteButtonCell)?.keepsState == true)
    }
}
