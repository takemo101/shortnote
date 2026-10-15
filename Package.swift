// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShortNote",
    platforms: [.macOS(.v13)],
    targets: [
        // アプリの本体。規則（モデル）・描画・OS との接点・UI を持つ。テストはここを対象にする。
        .target(name: "ShortNoteKit", path: "Sources/ShortNoteKit"),
        // 実行ファイル。起動するだけ。
        .executableTarget(name: "ShortNote", dependencies: ["ShortNoteKit"], path: "Sources/ShortNote"),
        .testTarget(name: "ShortNoteKitTests", dependencies: ["ShortNoteKit"], path: "Tests/ShortNoteKitTests"),
    ],
    swiftLanguageVersions: [.v5]
)
