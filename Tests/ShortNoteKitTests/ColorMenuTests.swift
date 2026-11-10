import AppKit
import Testing
@testable import ShortNoteKit

@Suite("色の見本：代表色のメニュー（SPEC §3.2）")
@MainActor
struct ColorMenuTests {
    private func menuView(_ swatch: ColorSwatchButton) throws -> ColorMenuView {
        let menu = try #require(swatch.menuProvider?())
        return try #require(menu.items.first?.view as? ColorMenuView)
    }

    private func cells(_ view: ColorMenuView) -> [ColorCellButton] { view.subviews.compactMap { $0 as? ColorCellButton } }

    @Test("代表色は 12 色で、すべて違う、読める色")
    func presets() {
        #expect(ColorMenuView.presets.count == 12)
        #expect(Set(ColorMenuView.presets.map(\.hex)).count == 12)
        #expect(ColorMenuView.presets.allSatisfy { $0.hex.count == 6 && UInt32($0.hex, radix: 16) != nil })
    }

    @Test("同じ色かは、sRGB の 8 ビットで比べる（わずかな差は同じ、別の色は別）")
    func sameColor() {
        let red = ColorMenuView.color(hex: "E53935")
        #expect(ColorMenuView.sameColor(red, NSColor(srgbRed: 0xE5 / 255.0, green: 0x39 / 255.0, blue: 0x35 / 255.0, alpha: 1)))
        #expect(ColorMenuView.sameColor(red, NSColor(srgbRed: 0xE5 / 255.0 + 0.001, green: 0x39 / 255.0, blue: 0x35 / 255.0, alpha: 1)))
        #expect(!ColorMenuView.sameColor(red, ColorMenuView.color(hex: "E53936")))
        #expect(!ColorMenuView.sameColor(.black, .white))
    }

    @Test("マスを押すと、見本の色が替わり、onChange で届く。メニューを開き直すと、いまの色のマスだけに輪が付く")
    func choosingACell() throws {
        let swatch = ColorSwatchButton()
        var received: [NSColor] = []
        swatch.onChange = { received.append($0) }
        // 起動時の黒には、黒のマスに輪が付く
        #expect(cells(try menuView(swatch)).filter(\.isCurrent).map { $0.accessibilityIdentifier() } == ["color-000000"])

        let view = try menuView(swatch)
        let cell = try #require(cells(view).first { $0.accessibilityIdentifier() == "color-E53935" })
        cell.sendAction(cell.action, to: cell.target)
        #expect(received.count == 1)
        #expect(ColorMenuView.sameColor(swatch.color, ColorMenuView.color(hex: "E53935")))
        #expect(received.first.map { ColorMenuView.sameColor($0, ColorMenuView.color(hex: "E53935")) } == true)
        #expect(cells(try menuView(swatch)).filter(\.isCurrent).map { $0.accessibilityIdentifier() } == ["color-E53935"])
    }

    @Test("代表色にない色（色のパネルで選んだ色）のときは、どのマスにも輪が付かない")
    func customColorHasNoMark() throws {
        let swatch = ColorSwatchButton()
        swatch.color = NSColor(srgbRed: 0.12, green: 0.34, blue: 0.56, alpha: 1)
        #expect(cells(try menuView(swatch)).allSatisfy { !$0.isCurrent })
    }
}
