import Testing
@testable import ShortNoteKit

@Suite struct KeyRouterTests {
    private let defaults = KeyBindings()

    private func route(_ chord: KeyChord, editing: Bool = false, composing: Bool = false, bindings: KeyBindings? = nil) -> KeyAction {
        KeyRouter.route(chord, bindings: bindings ?? defaults, isEditingText: editing, isComposingText: composing)
    }

    private func chord(_ command: Command, _ index: Int = 0) -> KeyChord {
        KeyBindings.defaults[command]![index]
    }

    @Test func defaultKeysRunTheirCommandsWhenNotEditing() {
        #expect(route(chord(.toolPen)) == .run(.toolPen))
        #expect(route(chord(.toolMove)) == .run(.toolMove))
        #expect(route(chord(.brushLarger)) == .run(.brushLarger))
        #expect(route(chord(.undo, 1)) == .run(.undo))   // ⌃Z も取り消し
        #expect(route(chord(.hidePanel)) == .run(.hidePanel))
    }

    @Test func plainCharacterKeysAreTypedTextWhileEditing() {
        #expect(route(chord(.toolPen), editing: true) == .passThrough)
        #expect(route(chord(.brushSmaller), editing: true) == .passThrough)
    }

    @Test func commandKeysStillWorkWhileEditing() {
        #expect(route(chord(.undo), editing: true) == .run(.undo))
        #expect(route(chord(.pasteImage), editing: true) == .run(.pasteImage))
        #expect(route(chord(.hidePanel), editing: true) == .run(.hidePanel))
    }

    @Test func standardEditingKeysGoToTheTextViewOnlyWhileEditing() {
        let copy = KeyChord(keyCode: 8, modifiers: .command, label: "C")
        #expect(route(copy, editing: true) == .textEditing(.copy))
        #expect(route(KeyChord(keyCode: 7, modifiers: .command, label: "X"), editing: true) == .textEditing(.cut))
        #expect(route(KeyChord(keyCode: 0, modifiers: .command, label: "A"), editing: true) == .textEditing(.selectAll))
        #expect(route(copy, editing: false) == .passThrough)
    }

    @Test func everyKeyBelongsToTheInputMethodWhileComposing() {
        #expect(route(chord(.hidePanel), editing: true, composing: true) == .passThrough)   // Esc は変換の取り消しに使われる
        #expect(route(chord(.undo), editing: true, composing: true) == .passThrough)
    }

    @Test func reassignedKeysFollowTheNewBindings() throws {
        let one = chord(.toolPen)
        let bindings = try #require(try? defaults.assigning(KeyChord(keyCode: 35, label: "P"), to: .toolPen).get())
        #expect(route(one, bindings: bindings) == .passThrough)                                       // 古いキーは効かない
        #expect(route(KeyChord(keyCode: 35, label: "P"), bindings: bindings) == .run(.toolPen))      // 新しいキーが効く
    }

    @Test func unassignedKeysPassThrough() {
        #expect(route(KeyChord(keyCode: 40, label: "K")) == .passThrough)
    }
}
