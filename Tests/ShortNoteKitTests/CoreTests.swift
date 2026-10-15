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
            Item(content: .line(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 25, y: 15)), color: black, size: 4),
        ]
        for original in items {
            let before = original.bounds
            let moved = original.translated(by: CGSize(width: 5, height: -3))
            #expect(moved.bounds == before.offsetBy(dx: 5, dy: -3))
            #expect(original.bounds == before)   // 元の値は変わらない
        }
    }

    @Test func clearingItems_removesEveryItemButKeepsTheBackground() {
        let background = tinyImage()
        let rect = CGRect(x: 3, y: 4, width: 50, height: 40)
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let doc = Document(background: background, backgroundRect: rect)
            .appending(rectItem(box))
            .appending(penItem([(0, 0), (5, 5)]))
            .appending(Item(content: .ellipse(box), color: black, size: 4))
            .appending(Item(content: .text("hi", box: box), color: black, size: 18))
            .appending(Item(content: .image(tinyImage(), box: box), color: black, size: 0))
            .appending(Item(content: .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 8, y: 6)), color: black, size: 4))
        let cleared = doc.clearingItems()
        #expect(cleared?.items.isEmpty == true)
        #expect(cleared?.background != nil)
        #expect(cleared?.backgroundRect == rect)
        #expect(doc.items.count == 6)   // 元の値は変わらない（取り消しで戻せる）
    }

    @Test func clearingItems_hasNothingToDoOnAnEmptyCanvas() {
        #expect(Document().clearingItems() == nil)
        #expect(Document(background: tinyImage(), backgroundRect: .zero).clearingItems() == nil)   // 背景だけでも、消すものは無い
    }

    @Test func appending_keepsThePreviousDocumentUntouched() {
        let empty = Document()
        let one = empty.appending(rectItem(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(empty.items.isEmpty)
        #expect(one.items.count == 1)
    }

    private let canvas = CGRect(x: 0, y: 0, width: 480, height: 320)

    @Test func translatingItem_rejectsAnOutOfRangeIndex() {
        let doc = Document().appending(rectItem(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let d = CGSize(width: 1, height: 1)
        #expect(doc.translatingItem(at: 1, by: d, keepingGrabAreaIn: canvas) == nil)
        #expect(doc.translatingItem(at: -1, by: d, keepingGrabAreaIn: canvas) == nil)
        #expect(doc.translatingItem(at: 0, by: d, keepingGrabAreaIn: canvas) != nil)
    }

    @Test func limited_leavesAMoveThatKeepsEnoughInsideUnchanged() {
        let area = CGRect(x: 94, y: 94, width: 112, height: 112)
        #expect(Document.limited(CGSize(width: 30, height: -20), for: area, in: canvas, keep: 16) == CGSize(width: 30, height: -20))
    }

    @Test func limited_stopsEachAxisWhereOnlyTheKeptLengthRemains() {
        let area = CGRect(x: 94, y: 94, width: 112, height: 112)
        // 右下へ大きく動かす：掴める範囲の左上が、キャンバスの右端・下端から 16 pt 手前まで（x: 480−16−94、y: 320−16−94）
        #expect(Document.limited(CGSize(width: 9999, height: 9999), for: area, in: canvas, keep: 16) == CGSize(width: 370, height: 210))
        // 左上へ大きく動かす：掴める範囲の右下が、キャンバスの左端・上端から 16 pt 内側まで（x: 16−206、y: 16−206）
        #expect(Document.limited(CGSize(width: -9999, height: -9999), for: area, in: canvas, keep: 16) == CGSize(width: -190, height: -190))
    }

    @Test func limited_keepsTheWholeOfAnItemSmallerThanTheKeptLength() {
        let area = CGRect(x: 100, y: 100, width: 10, height: 10)
        let r = Document.limited(CGSize(width: 9999, height: 0), for: area, in: canvas, keep: 16)
        #expect(r.width == 370, "got \(r.width)")
    }

    @Test func hasMovedItem_isFalseWhenTheLimitStoppedTheMoveEntirely() {
        // 掴める範囲（外接する範囲＋余白 4 pt。線の太さ 4 で、矩形から 6 pt 外側）の左上が、ちょうど (464, 304)＝縁から 16 pt の位置にある楕円。これ以上、右下へは動かせない。
        let base = Document().appending(Item(content: .ellipse(CGRect(x: 470, y: 310, width: 100, height: 100)), color: black, size: 4))
        let stuck = base.translatingItem(at: 0, by: CGSize(width: 50, height: 50), keepingGrabAreaIn: canvas)
        #expect(stuck?.hasMovedItem(at: 0, since: base) == false)
        let back = base.translatingItem(at: 0, by: CGSize(width: -50, height: -50), keepingGrabAreaIn: canvas)   // 戻す向きは動く
        #expect(back?.hasMovedItem(at: 0, since: base) == true)
        #expect(base.hasMovedItem(at: 5, since: base) == false)   // 範囲外の番号
    }

    @Test func limited_neverPullsAnItemThatIsAlreadyMostlyOutside() {
        // 右の縁から 3 pt だけ中にある（x 477〜）要素を、いま掴んだ。その 3 pt は、そのまま保てる（動かし始めで飛ばない）が、これ以上は外へ出せない。
        let area = CGRect(x: 477, y: 100, width: 100, height: 50)
        #expect(Document.limited(CGSize(width: 0, height: 0), for: area, in: canvas, keep: 16) == .zero)
        #expect(Document.limited(CGSize(width: 50, height: 0), for: area, in: canvas, keep: 16).width == 0)
        #expect(Document.limited(CGSize(width: -50, height: 0), for: area, in: canvas, keep: 16).width == -50)
    }

    @Test func translatingItem_afterAHugeMoveFromAnEmptyCorner_theItemCanStillBeGrabbed() {
        // 楕円（100,100)〜(200,200）の、何も描かれていない左上の角（103,103）を掴んで、右下の遠くまで動かした場合と同じ量。
        let doc = Document().appending(Item(content: .ellipse(CGRect(x: 100, y: 100, width: 100, height: 100)), color: black, size: 4))
        let moved = doc.translatingItem(at: 0, by: CGSize(width: 377, height: 217), keepingGrabAreaIn: canvas)
        let far = doc.translatingItem(at: 0, by: CGSize(width: 99999, height: 99999), keepingGrabAreaIn: canvas)
        // キャンバスの中のクリックで、また掴める（右端・下端は、クリックの位置の範囲に入らないので、その手前で掴む）
        #expect(moved?.topItemIndex(at: CGPoint(x: 470, y: 310)) == 0)
        #expect(far?.topItemIndex(at: CGPoint(x: 479.5, y: 319.5)) == 0)
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
