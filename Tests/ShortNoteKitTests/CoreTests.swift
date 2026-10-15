import CoreGraphics
import Foundation
import Testing
@testable import ShortNoteKit

private let black = CGColor(gray: 0, alpha: 1)

private func tinyImage() -> ImportedImage {
    let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ImportedImage(cgImage: ctx.makeImage()!, pointSize: CGSize(width: 2, height: 2))
}

private func rectItem(_ r: CGRect, size: CGFloat = 4) -> Item {
    Item(content: .rect(r), color: black, size: size)
}

private func penItem(_ pts: [(CGFloat, CGFloat)], size: CGFloat = 4) -> Item {
    Item(content: .pen(points: pts.map { StrokePoint(point: CGPoint(x: $0.0, y: $0.1), pressure: 1) }), color: black, size: size)
}

// MARK: - History

@Suite struct HistoryTests {
    @Test func undoReturnsThePreviousStateAndRedoComesBack() {
        var h = History<Int>()
        h.record(previous: 1)            // 1 → 2 の操作
        #expect(h.undo(current: 2) == 1)
        #expect(h.redo(current: 1) == 2)
        #expect(h.canUndo)
        #expect(!h.canRedo)
    }

    @Test func emptyHistoryHasNothingToUndoOrRedo() {
        var h = History<Int>()
        #expect(h.undo(current: 0) == nil)
        #expect(h.redo(current: 0) == nil)
        #expect(!h.canUndo && !h.canRedo)
    }

    @Test func aNewOperationDiscardsTheRedoStack() {
        var h = History<Int>()
        h.record(previous: 1)
        _ = h.undo(current: 2)           // 状態 1 に戻った
        h.record(previous: 1)            // 別の操作をした
        #expect(h.redo(current: 3) == nil)
    }

    @Test func theOldestEntriesAreDroppedBeyondTheLimit() {
        var h = History<Int>(limit: 3)
        for i in 0..<10 { h.record(previous: i) }   // 0〜9 を積む → 古い 0〜6 が落ち、7, 8, 9 が残る
        var state = 10
        var restored: [Int] = []
        while let previous = h.undo(current: state) { restored.append(previous); state = previous }
        #expect(restored == [9, 8, 7])
    }

    @Test func undoThenRedoWalksTheSameStates() {
        var h = History<String>()
        h.record(previous: "a")          // a → b
        h.record(previous: "b")          // b → c
        #expect(h.undo(current: "c") == "b")
        #expect(h.undo(current: "b") == "a")
        #expect(h.redo(current: "a") == "b")
        #expect(h.redo(current: "b") == "c")
        #expect(h.redo(current: "c") == nil)
    }
}

// MARK: - Item / Document

@Suite struct DocumentTests {
    @Test func bounds_includeTheStrokeWidthOfShapes() {
        let item = rectItem(CGRect(x: 100, y: 100, width: 50, height: 50), size: 10)
        #expect(item.bounds == CGRect(x: 95, y: 95, width: 60, height: 60))
    }

    @Test func bounds_ofAPenStrokeCoverAllPoints() {
        let item = penItem([(10, 20), (40, 5), (30, 60)], size: 4)
        #expect(item.bounds == CGRect(x: 8, y: 3, width: 34, height: 59))
    }

    @Test func translated_movesEveryKindWithoutChangingTheOriginal() {
        let tiny = tinyImage()
        let items: [Item] = [
            penItem([(0, 0), (10, 10)]),
            rectItem(CGRect(x: 5, y: 5, width: 20, height: 10)),
            Item(content: .ellipse(CGRect(x: 5, y: 5, width: 20, height: 10)), color: black, size: 4),
            Item(content: .text("hi", box: CGRect(x: 5, y: 5, width: 20, height: 10)), color: black, size: 18),
            Item(content: .image(tiny, box: CGRect(x: 5, y: 5, width: 20, height: 10)), color: black, size: 0),
        ]
        for original in items {
            let before = original.bounds
            let moved = original.translated(by: CGSize(width: 5, height: -3))
            #expect(moved.bounds == before.offsetBy(dx: 5, dy: -3))
            #expect(original.bounds == before)   // 元の値は変わらない
        }
    }

    @Test func appending_keepsThePreviousDocumentUntouched() {
        let empty = Document()
        let one = empty.appending(rectItem(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(empty.items.isEmpty)
        #expect(one.items.count == 1)
    }

    @Test func translatingItem_rejectsAnOutOfRangeIndex() {
        let doc = Document().appending(rectItem(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(doc.translatingItem(at: 1, by: CGSize(width: 1, height: 1)) == nil)
        #expect(doc.translatingItem(at: -1, by: CGSize(width: 1, height: 1)) == nil)
        #expect(doc.translatingItem(at: 0, by: CGSize(width: 1, height: 1)) != nil)
    }

    @Test func topItemIndex_picksTheFrontMostItemUnderThePoint() {
        let doc = Document()
            .appending(rectItem(CGRect(x: 0, y: 0, width: 100, height: 100)))
            .appending(rectItem(CGRect(x: 50, y: 50, width: 100, height: 100)))
        #expect(doc.topItemIndex(at: CGPoint(x: 60, y: 60)) == 1)     // 重なっているところは手前（後ろの要素）
        #expect(doc.topItemIndex(at: CGPoint(x: 10, y: 10)) == 0)
        #expect(doc.topItemIndex(at: CGPoint(x: 300, y: 300)) == nil)
    }

    @Test func topItemIndex_grabsTheInsideOfAnOutlinedShape() {
        let doc = Document().appending(rectItem(CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(doc.topItemIndex(at: CGPoint(x: 50, y: 50)) == 0)
    }
}

// MARK: - CanvasSize

@Suite struct CanvasSizeTests {
    private let wide = CanvasSize.Limits(availablePoints: CGSize(width: 2000, height: 1200))   // 最大 4000 × 2400 px

    @Test func parse_acceptsAValidSize() {
        #expect(CanvasSize.parse(width: 1280, height: 720, limits: wide) == .success(CanvasSize.presets[1].size))
    }

    @Test(arguments: [(959, 640), (960, 639), (100, 100)])
    func parse_rejectsBelowTheMinimum(_ w: Int, _ h: Int) {
        #expect(CanvasSize.parse(width: w, height: h, limits: wide) == .failure(.belowMinimum))
    }

    @Test(arguments: [(961, 640), (960, 641), (1281, 721)])
    func parse_rejectsOddPixelCounts(_ w: Int, _ h: Int) {
        #expect(CanvasSize.parse(width: w, height: h, limits: wide) == .failure(.notEven))
    }

    @Test func parse_rejectsWhatDoesNotFitTheScreen() {
        #expect(CanvasSize.parse(width: 4002, height: 700, limits: wide) == .failure(.exceedsLimits(wide)))
        guard case .success(let size) = CanvasSize.parse(width: 4000, height: 2400, limits: wide) else { Issue.record("上限ちょうどのサイズは有効なはず"); return }
        #expect(size.width == 4000 && size.height == 2400)
    }

    @Test func limits_areEvenAndNeverExceedTheExportCap() {
        let huge = CanvasSize.Limits(availablePoints: CGSize(width: 10_000, height: 5000.7))
        #expect(huge.width == CanvasSize.maxSide)
        #expect(huge.height == CanvasSize.maxSide)
        let odd = CanvasSize.Limits(availablePoints: CGSize(width: 1000.9, height: 700.4))   // 2001.8 → 2001 → 偶数に 2000
        #expect(odd.width == 2000)
        #expect(odd.height == 1400)
    }

    @Test func fitting_shrinksToTheLargestValidSize() {
        let small = CanvasSize.Limits(availablePoints: CGSize(width: 800, height: 450))      // 1600 × 900
        let fitted = CanvasSize.fitting(CanvasSize.presets[2].size, in: small)              // 1920 × 1080 が、収まらない
        #expect(fitted == (try? CanvasSize.parse(width: 1600, height: 900, limits: small).get()))
    }

    @Test func fitting_neverGoesBelowTheMinimumEvenOnATinyScreen() {
        let tiny = CanvasSize.Limits(availablePoints: CGSize(width: 100, height: 100))
        #expect(CanvasSize.fitting(CanvasSize.presets[1].size, in: tiny) == .minimum)
    }

    @Test func everyPresetIsAValidSize() {
        let wide = CanvasSize.Limits(availablePoints: CGSize(width: 4096, height: 4096))
        for preset in CanvasSize.presets {
            #expect(CanvasSize.parse(width: preset.size.width, height: preset.size.height, limits: wide) == .success(preset.size))
        }
    }
}

@Suite struct CanvasSizeStoreTests {
    /// 他のテストと混ざらない、使い捨ての保存先。
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "ShortNoteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func load_returnsTheStandardSizeWhenNothingIsSaved() {
        let (defaults, cleanup) = isolatedDefaults(); defer { cleanup() }
        #expect(CanvasSizeStore(defaults: defaults).load() == .standard)
    }

    @Test func saveThenLoad_roundTrips() {
        let (defaults, cleanup) = isolatedDefaults(); defer { cleanup() }
        let store = CanvasSizeStore(defaults: defaults)
        store.save(CanvasSize.presets[2].size)
        #expect(store.load() == CanvasSize.presets[2].size)
    }

    @Test(arguments: [(100, 100), (961, 640), (20000, 700), (0, 0)])
    func load_fallsBackToTheStandardSizeWhenTheSavedValueIsInvalid(_ w: Int, _ h: Int) {
        let (defaults, cleanup) = isolatedDefaults(); defer { cleanup() }
        defaults.set(w, forKey: "canvasWidthPx"); defaults.set(h, forKey: "canvasHeightPx")
        #expect(CanvasSizeStore(defaults: defaults).load() == .standard)
    }
}
