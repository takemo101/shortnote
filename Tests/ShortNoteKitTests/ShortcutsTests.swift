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
        let one = try b.resetting(.undo).get()
        #expect(!one.isCustomized(.undo))
        #expect(one.isCustomized(.toolPen))
        #expect(b.resettingAll() == KeyBindings())
        #expect(!b.resettingAll().hasCustomizations)
    }

    @Test func resettingIsRefusedWhileAnotherCommandHoldsTheDefaultKey() throws {
        // ペンのキー 1 を外し、円に 1 を割り当てる。そのあとペンを初期値に戻すと、1 が 2 つのコマンドに重なってしまう。
        var b = KeyBindings().clearing(.toolPen)
        b = try b.assigning(one, to: .toolEllipse).get()
        #expect(b.resetting(.toolPen) == .failure(.conflict(.toolEllipse)))
        // 円を先に戻す（円の既定は 2。1 は空く）と、ペンも戻せる。
        let freed = try b.resetting(.toolEllipse).get()
        #expect(try freed.resetting(.toolPen).get() == KeyBindings())
    }

    @Test func resettingTheGlobalCommandIsRefusedWhenItsDefaultKeyIsTaken() throws {
        let ctrlOptN = chord(45, [.control, .option], "N")
        var b = KeyBindings().clearing(.showPanel)
        b = try b.assigning(ctrlOptN, to: .hidePanel).get()
        #expect(b.resetting(.showPanel) == .failure(.conflict(.hidePanel)))
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
            #expect(loaded.bindings.chords(for: .toolRect).isEmpty)   // 重なって無効になったコマンドは、既定の 3 に戻らず、割り当てなしになる
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

// MARK: - キーボード配列ごとの既定（`[` `]`）

@Suite struct LayoutDefaultsTests {
    /// US 配列: `[` は 33、`]` は 30。JIS 配列: 33 は `@`、`[` は 30、`]` は 42。
    private let us: [UInt16: String] = [33: "[", 30: "]"]
    private let jis: [UInt16: String] = [33: "@", 30: "[", 42: "]"]

    @Test func bracketKeysFollowTheLayout() throws {
        let onJIS = KeyBindings.standardDefaults(characterForKeyCode: { jis[$0] })
        #expect(onJIS[.brushSmaller] == [chord(30, "[")])
        #expect(onJIS[.brushLarger] == [chord(42, "]")])
        #expect(onJIS[.brushSmaller]?.first?.label == "[" && onJIS[.brushLarger]?.first?.label == "]")   // 表示は、どの配列でも [ ]

        let onUS = KeyBindings.standardDefaults(characterForKeyCode: { us[$0] })
        #expect(onUS == KeyBindings.defaults)
    }

    @Test func bracketKeysFallBackToTheUSPositionsWhenTheLayoutCannotBeRead() {
        #expect(KeyBindings.standardDefaults(characterForKeyCode: { _ in nil }) == KeyBindings.defaults)
    }

    @Test func onlyTheBracketKeysDependOnTheLayout() {
        let onJIS = KeyBindings.standardDefaults(characterForKeyCode: { jis[$0] })
        for command in Command.allCases where command != .brushSmaller && command != .brushLarger {
            #expect(onJIS[command] == KeyBindings.defaults[command])
        }
    }

    @Test func bindingsOnAnotherLayoutResolveThatLayoutsKeys() {
        let b = KeyBindings(defaultChords: KeyBindings.standardDefaults(characterForKeyCode: { jis[$0] }))
        #expect(b.command(for: chord(30, "["), whileEditingText: false) == .brushSmaller)
        #expect(b.command(for: chord(42, "]"), whileEditingText: false) == .brushLarger)
        #expect(b.command(for: chord(33, "@"), whileEditingText: false) == nil)   // JIS の @ キーは、ブラシのキーではない
    }

    @Test func savedOverridesAreKeptAndLayoutDefaultsAreNotSaved() throws {
        let name = "ShortNoteTests.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: name)); defer { ud.removePersistentDomain(forName: name) }
        let layoutDefaults = KeyBindings.standardDefaults(characterForKeyCode: { jis[$0] })
        let store = KeyBindingsStore(defaults: ud, defaultChords: layoutDefaults)

        let changed = try KeyBindings(defaultChords: layoutDefaults).assigning(chord(35, "P"), to: .toolPen).get()
        store.save(changed)
        let json = String(decoding: try #require(ud.data(forKey: "keyBindings")), as: UTF8.self)
        #expect(!json.contains("brush"))   // 既定との差分だけを保存する。配列由来の既定は保存しない

        let loaded = store.load()
        #expect(loaded.issue == nil)
        #expect(loaded.bindings == changed)
        #expect(loaded.bindings.chords(for: .brushLarger) == [chord(42, "]")])
    }

    @MainActor
    @Test func theDefaultsOfTheRealLayoutNeverCollideOrUseReservedKeys() {
        // この Mac の、いまの配列（TIS はメインスレッドで使う）。どの配列でも、既定どうしが重ならず、予約済みのキーも使わない。
        let table = KeyboardLayout.characters()
        let b = KeyBindings(defaultChords: KeyBindings.standardDefaults(characterForKeyCode: { table[$0] }))
        #expect(!hasConflict(b))
        for command in Command.allCases {
            for c in b.chords(for: command) { #expect(!KeyBindings.reservedChords.contains(c)) }
        }
    }

    @Test func bracketKeysThatCollideWithOtherDefaultsFallBackToTheUSPositions() {
        // `[` が数字の段（「2」のキー = 19）にある配列（Programmer Dvorak など）。円のキーと重なるので、US の位置にする。
        let programmerDvorak: [UInt16: String] = [19: "[", 30: "]"]
        #expect(KeyBindings.standardDefaults(characterForKeyCode: { programmerDvorak[$0] }) == KeyBindings.defaults)
        // 片方（`]`）しか見つからない配列。見つかった方だけを使うと、もう片方の既定の位置と重なりうるので、両方を US の位置にする。
        let onlyOne: [UInt16: String] = [30: "["]
        #expect(KeyBindings.standardDefaults(characterForKeyCode: { onlyOne[$0] }) == KeyBindings.defaults)
    }

    @Test func aSavedKeyWinsOverALayoutDerivedDefaultWhenTheKeyboardTypeChanges() throws {
        // US の配列で、文字ツールに 42（US の `\`）を保存した。あとで JIS のキーボードをつなぐと、ブラシ太くの既定が 42 になる。
        let name = "ShortNoteTests.\(UUID().uuidString)"
        let ud = try #require(UserDefaults(suiteName: name)); defer { ud.removePersistentDomain(forName: name) }
        let backslash = chord(42, "\\")
        KeyBindingsStore(defaults: ud).save(try KeyBindings().assigning(backslash, to: .toolText).get())

        let jis = KeyBindings.standardDefaults(characterForKeyCode: { self.jis[$0] })
        let loaded = KeyBindingsStore(defaults: ud, defaultChords: jis).load()
        #expect(loaded.bindings.chords(for: .toolText) == [backslash])         // 利用者が選んだキーは残る
        #expect(loaded.bindings.chords(for: .brushLarger).isEmpty)              // 配列由来の既定の側が、割り当てなしになる
        #expect(loaded.bindings.chords(for: .brushSmaller) == [chord(30, "[")])
        #expect(!hasConflict(loaded.bindings))
        #expect(loaded.issue?.contains("ブラシを太く") == true)                  // 理由を知らせる
        // 保存し直しても、利用者の選択は変わらない。US に戻すと、ブラシ太くの既定（30）は「初期値」で戻せる。
        let store = KeyBindingsStore(defaults: ud, defaultChords: jis)
        store.save(loaded.bindings)
        #expect(store.load().bindings.chords(for: .toolText) == [backslash])
    }
}
