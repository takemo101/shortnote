import Foundation
import Testing
@testable import ShortNoteKit

private func chord(_ code: UInt16, _ mods: KeyModifiers, _ label: String) -> KeyChord {
    KeyChord(keyCode: code, modifiers: mods, label: label)
}

private func chord(_ code: UInt16, _ label: String) -> KeyChord {
    KeyChord(keyCode: code, label: label)
}

private let cmdZ = chord(6, .command, "Z")
private let one = chord(18, "1")
private let two = chord(19, "2")

/// 実際に有効なキーが複数コマンドに重複していないこと。
private func hasConflict(_ b: KeyBindings) -> Bool {
    let all = Command.allCases.flatMap { b.chords(for: $0) }
    return Set(all).count != all.count
}

@Suite struct DefaultMapTests {
    @Test func noChordIsAssignedToTwoCommands() {
        #expect(!hasConflict(KeyBindings()))
    }

    @Test(arguments: Command.allCases)
    func everyCommandHasADefault(command: Command) {
        #expect(!KeyBindings.defaults[command, default: []].isEmpty)
    }

    @Test(arguments: Command.allCases)
    func defaultsAreNotReserved(command: Command) {
        for c in KeyBindings.defaults[command, default: []] {
            #expect(!KeyBindings.reservedChords.contains(c))
        }
        if command.isGlobal {
            #expect(KeyBindings.defaults[command, default: []].allSatisfy { $0.isGlobalSafe })
        }
    }

    @Test func onlyShowPanelIsGlobal() {
        #expect(Command.allCases.filter(\.isGlobal) == [.showPanel])
    }
}

@Suite struct LookupTests {
    let b = KeyBindings()

    @Test func bareKeyResolvesOnlyWhenNotEditing() {
        #expect(b.command(for: one, whileEditingText: false) == .toolPen)
        #expect(b.command(for: one, whileEditingText: true) == nil)
    }

    @Test func commandAndControlChordsResolveWhileEditing() {
        #expect(b.command(for: cmdZ, whileEditingText: true) == .undo)
        #expect(b.command(for: chord(6, .control, "Z"), whileEditingText: true) == .undo)
    }

    @Test func bareEscResolvesWhileEditing() {
        #expect(b.command(for: chord(53, "Esc"), whileEditingText: true) == .hidePanel)
    }

    @Test func unboundChordResolvesToNil() {
        #expect(b.command(for: chord(40, .command, "K"), whileEditingText: false) == nil)
    }

    @Test func typingSafetyAndGlobalSafety() {
        #expect(!chord(0, "A").isTypingSafe)
        #expect(!chord(0, [.option, .shift], "A").isTypingSafe)
        #expect(chord(122, "F1").isTypingSafe)
        #expect(!chord(0, .shift, "A").isGlobalSafe)
        #expect(chord(0, .option, "A").isGlobalSafe)
        #expect(chord(122, "F1").isGlobalSafe)
    }
}

@Suite struct AssigningTests {
    @Test func conflictReportsOwner() {
        #expect(KeyBindings().assigning(one, to: .toolEllipse) == .failure(.conflict(.toolPen)))
    }

    @Test(arguments: Array(KeyBindings.reservedChords))
    func reservedChordIsRejected(reserved: KeyChord) {
        #expect(KeyBindings().assigning(reserved, to: .toolRect) == .failure(.reserved))
    }

    @Test func globalCommandNeedsModifier() throws {
        #expect(KeyBindings().assigning(chord(40, "K"), to: .showPanel) == .failure(.globalNeedsModifier))
        let ok = try KeyBindings().assigning(chord(40, [.control, .option], "K"), to: .showPanel).get()
        #expect(ok.chords(for: .showPanel).map(\.displayString) == ["⌃⌥K"])
    }

    @Test func assigningTheSameChordIsANoOp() throws {
        let b = KeyBindings()
        let result = try b.assigning(one, to: .toolPen).get()
        #expect(result == b)
    }

    @Test func assigningReplacesAllExistingChords() throws {
        let b = try KeyBindings().assigning(chord(40, .command, "K"), to: .undo).get()
        #expect(b.chords(for: .undo).count == 1)
        #expect(b.command(for: cmdZ, whileEditingText: false) == nil)
        #expect(b.command(for: chord(6, .control, "Z"), whileEditingText: false) == nil)
        #expect(b.isCustomized(.undo))
    }

    @Test func assigningTheDefaultBackRemovesTheOverride() throws {
        let b = try KeyBindings().assigning(chord(40, .command, "K"), to: .openImage).get()
        #expect(b.hasCustomizations)
        let back = try b.assigning(chord(31, .command, "O"), to: .openImage).get()
        #expect(!back.hasCustomizations)
        #expect(back == KeyBindings())
    }

    @Test func clearingUnassignsAndFreesTheChord() throws {
        let b = KeyBindings().clearing(.toolPen)
        #expect(b.chords(for: .toolPen).isEmpty)
        #expect(b.isCustomized(.toolPen))
        #expect(b.command(for: one, whileEditingText: false) == nil)
        let moved = try b.assigning(one, to: .toolEllipse).get()
        #expect(moved.command(for: one, whileEditingText: false) == .toolEllipse)
    }

    @Test func resetting() throws {
        let b = try KeyBindings().assigning(chord(40, .command, "K"), to: .undo).get().clearing(.toolPen)
        let one = b.resetting(.undo)
        #expect(!one.isCustomized(.undo))
        #expect(one.isCustomized(.toolPen))
        #expect(b.resettingAll() == KeyBindings())
        #expect(!b.resettingAll().hasCustomizations)
    }
}

@Suite struct DisplayTests {
    @Test func displayStringOrdersModifiers() {
        #expect(chord(45, [.command, .shift, .option, .control], "N").displayString == "⌃⌥⇧⌘N")
        #expect(chord(45, [.control, .option], "N").displayString == "⌃⌥N")
        #expect(chord(6, [.command, .shift], "Z").displayString == "⇧⌘Z")
        #expect(one.displayString == "1")
        #expect(chord(53, "Esc").displayString == "Esc")
    }

    @Test func equalityAndHashIgnoreLabel() {
        let a = chord(6, .command, "Z")
        let b = chord(6, .command, "z")
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a != chord(6, .control, "Z"))
        #expect(a != chord(7, .command, "Z"))
    }

    @Test func chordCodableRoundTrip() throws {
        let original = chord(6, [.command, .shift], "Z")
        let decoded = try JSONDecoder().decode(KeyChord.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.label == "Z")
    }
}

@Suite struct StoreTests {
    private func withStore(_ body: (KeyBindingsStore, UserDefaults) throws -> Void) rethrows {
        let name = "shortnote.test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        defer { ud.removePersistentDomain(forName: name) }
        try body(KeyBindingsStore(defaults: ud), ud)
    }

    private func setRaw(_ json: String, _ ud: UserDefaults) {
        ud.set(Data(json.utf8), forKey: "keyBindings")
    }

    @Test func missingDataYieldsDefaultsWithoutIssue() {
        withStore { store, _ in
            #expect(store.load() == .init(bindings: KeyBindings(), issue: nil))
        }
    }

    @Test func roundTrip() throws {
        try withStore { store, _ in
            let b = try KeyBindings()
                .assigning(chord(40, .command, "K"), to: .undo).get()
                .clearing(.toolPen)
            store.save(b)
            let loaded = store.load()
            #expect(loaded.issue == nil)
            #expect(loaded.bindings == b)
        }
    }

    @Test func corruptDataFallsBackToDefaults() {
        withStore { store, ud in
            ud.set(Data("not json".utf8), forKey: "keyBindings")
            let loaded = store.load()
            #expect(loaded.bindings == KeyBindings())
            #expect(loaded.issue != nil)
        }
    }

    @Test func unknownConflictingAndReservedEntriesAreDropped() {
        withStore { store, ud in
            // toolRect に "1"（toolPen と衝突）、toolText に ⌘C（予約）、存在しないコマンド、
            // undo に有効なキー ⌘K。
            setRaw("""
            {"bogus":[{"keyCode":1,"modifiers":8,"label":"S"}],
             "toolRect":[{"keyCode":18,"modifiers":0,"label":"1"}],
             "toolText":[{"keyCode":8,"modifiers":8,"label":"C"}],
             "undo":[{"keyCode":40,"modifiers":8,"label":"K"}]}
            """, ud)
            let loaded = store.load()
            #expect(loaded.issue != nil)
            #expect(!hasConflict(loaded.bindings))
            #expect(loaded.bindings.chords(for: .toolPen) == [one])
            #expect(loaded.bindings.chords(for: .undo).map(\.displayString) == ["⌘K"])
            #expect(!loaded.bindings.chords(for: .toolText).contains(chord(8, .command, "C")))
            #expect(!loaded.bindings.chords(for: .toolRect).contains(one))
        }
    }

    @Test func swappedBindingsLoadWithoutLosingEither() throws {
        try withStore { store, _ in
            var b = KeyBindings().clearing(.toolPen).clearing(.toolEllipse)
            b = try b.assigning(two, to: .toolPen).get().assigning(one, to: .toolEllipse).get()
            store.save(b)
            let loaded = store.load()
            #expect(loaded.issue == nil)
            #expect(loaded.bindings == b)
        }
    }

    @Test func noOverridesRemovesTheKey() throws {
        try withStore { store, ud in
            store.save(try KeyBindings().assigning(chord(40, .command, "K"), to: .undo).get())
            #expect(ud.data(forKey: "keyBindings") != nil)
            store.save(KeyBindings())
            #expect(ud.object(forKey: "keyBindings") == nil)
        }
    }
}
