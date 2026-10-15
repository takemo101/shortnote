import Testing
@testable import ShortNoteKit

/// テストターゲットがライブラリをリンクできること（これ以降のテストの土台）。
@Suite struct PackageSmokeTests {
    @Test func canvasMinimumIsEvenInPixels() {
        #expect(Int(CanvasView.minimumSize.width * CanvasView.exportScale) % 2 == 0)
    }
}
