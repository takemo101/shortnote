import AppKit
import ApplicationServices
import Carbon.HIToolbox

// ShortNote native E2E（verifying-macos-apps 準拠）。自分で起動した PID だけを操作する。
// 使い方（リポジトリのルートで）:
//   /usr/bin/swift scripts/native-e2e.swift "$PWD/build/ShortNote.app/Contents/MacOS/ShortNote" [--artifacts DIR]
// 終了コード: 1 = fail あり、77 = blocked あり（fail がなければ）、0 = 全 pass
let argv = CommandLine.arguments
guard argv.count >= 2, !argv[1].hasPrefix("-") else { print("usage: native-e2e.swift <ShortNote executable> [--artifacts DIR]"); exit(2) }
let buildExe = URL(fileURLWithPath: argv[1]).standardizedFileURL.resolvingSymlinksInPath().path
var artifactsRoot = FileManager.default.currentDirectoryPath + "/build/native-e2e"
if let i = argv.firstIndex(of: "--artifacts"), i + 1 < argv.count { artifactsRoot = URL(fileURLWithPath: argv[i + 1]).standardizedFileURL.path }
let runStamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
let work = "\(artifactsRoot)/run-\(runStamp)"
try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

var results: [(String, String, String)] = []
func rec(_ id: String, _ v: String, _ d: String) { results.append((id, v, d)); print("[\(v)] \(id): \(d)"); fflush(stdout) }

@discardableResult
func sh(_ a: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = a
    let o = Pipe(); p.standardOutput = o; p.standardError = o
    try? p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
func wait(_ secs: Double, _ f: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if f() { return true }; usleep(80_000) }
    return f()
}

// ---------- images ----------
func makeImage(_ path: String, _ c: NSColor) {
    let img = NSImage(size: NSSize(width: 800, height: 500))
    img.lockFocus(); c.setFill(); NSRect(x: 0, y: 0, width: 800, height: 500).fill(); img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
struct Px { var r: Double, g: Double, b: Double, a: Double
    var lum: Double { 0.299 * r + 0.587 * g + 0.114 * b } }
func load(_ path: String) -> NSBitmapImageRep? { NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) }
func px(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Px {
    let x = min(max(x, 0), rep.pixelsWide - 1), y = min(max(y, 0), rep.pixelsHigh - 1)
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    return Px(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
}
/// 書き出し PNG の画素位置を、キャンバスのポイント座標に換算するための現在のキャンバス幅。リサイズのケースでだけ変える。
var canvasWidthPt: Double = 480
/// canvas point (pt, top-left origin) -> darkest pixel in a 5x5 neighbourhood of the export
func darkest(_ rep: NSBitmapImageRep, _ cx: Double, _ cy: Double) -> Px {
    let s = Double(rep.pixelsWide) / canvasWidthPt
    var best = px(rep, Int(cx * s), Int(cy * s))
    for dx in -2...2 { for dy in -2...2 { let p = px(rep, Int(cx * s) + dx, Int(cy * s) + dy); if p.lum < best.lum { best = p } } }
    return best
}
func at(_ rep: NSBitmapImageRep, _ cx: Double, _ cy: Double) -> Px { let s = Double(rep.pixelsWide) / canvasWidthPt; return px(rep, Int(cx * s), Int(cy * s)) }
func isTeal(_ p: Px) -> Bool { abs(p.r - 0) < 0.12 && abs(p.g - 0.8) < 0.12 && abs(p.b - 0.85) < 0.12 && p.a > 0.95 }
func isDark(_ p: Px) -> Bool { p.lum < 0.15 && p.a > 0.95 }
func thickness(_ rep: NSBitmapImageRep, col cx: Double, around cy: Double) -> Int {
    let s = Double(rep.pixelsWide) / canvasWidthPt; let x = Int(cx * s); var n = 0
    for y in max(0, Int(cy * s) - 120)..<min(rep.pixelsHigh, Int(cy * s) + 120) where isDark(px(rep, x, y)) { n += 1 }
    return n
}

// ---------- windows / hit target ----------
func infos(_ onScreen: Bool) -> [[String: Any]] {
    (CGWindowListCopyWindowInfo(onScreen ? [.optionOnScreenOnly] : [.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
}
func owner(_ w: [String: Any]) -> pid_t { (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1 }
func bounds(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) ?? .zero }
func candWindow(_ pid: pid_t, onScreen: Bool = true) -> [String: Any]? { infos(onScreen).first { owner($0) == pid && ($0[kCGWindowName as String] as? String) == "ShortNote" } }
func hitOwner(_ p: CGPoint) -> pid_t? {
    for w in infos(true) {
        let a = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        if a > 0, bounds(w).contains(p) { return owner(w) }
    }
    return nil
}

// ---------- AX ----------
func ax(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? (v as AnyObject?) : nil }
func axs(_ e: AXUIElement, _ a: String) -> String { (ax(e, a) as? String) ?? "" }
func walk(_ e: AXUIElement, _ depth: Int = 0, _ f: (AXUIElement) -> Void) {
    guard depth < 8 else { return }
    f(e)
    for c in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, depth + 1, f) }
}
func collect(_ app: AXUIElement, _ pred: (AXUIElement) -> Bool) -> [AXUIElement] { var r: [AXUIElement] = []; walk(app) { if pred($0) { r.append($0) } }; return r }
func dumpTree(_ app: AXUIElement) -> String {
    var s = ""; var lines = 0
    func rec(_ e: AXUIElement, _ d: Int) { guard d < 8, lines < 40 else { return }; lines += 1
        s += String(repeating: " ", count: d * 2) + "\(axs(e, "AXRole")) title='\(axs(e, "AXTitle"))' desc='\(axs(e, "AXDescription"))' help='\(axs(e, "AXHelp"))'\n"
        for c in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { rec(c, d + 1) } }
    rec(app, 0); return s
}

// ---------- input (guarded) ----------
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(12_000) }
func line(_ a: CGPoint, _ b: CGPoint, steps: Int = 24) -> [CGPoint] { (0...steps).map { CGPoint(x: a.x + (b.x - a.x) * CGFloat($0) / CGFloat(steps), y: a.y + (b.y - a.y) * CGFloat($0) / CGFloat(steps)) } }
func drag(_ pts: [CGPoint], pid: pid_t) -> Bool {
    for p in [pts.first!, pts[pts.count / 2], pts.last!] where hitOwner(p) != pid { print("   guard refused drag at \(p): front-most owner=\(String(describing: hitOwner(p))) want \(pid)"); return false }
    post(.mouseMoved, pts[0]); post(.leftMouseDown, pts[0])
    for p in pts.dropFirst() { post(.leftMouseDragged, p) }
    post(.leftMouseUp, pts.last!); usleep(150_000); return true
}
func keyGuard(_ pid: pid_t, _ app: AXUIElement) -> String? {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
    guard wait(2, { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else {
        return "frontmost pid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) != candidate \(pid)" }
    guard let fw = ax(app, "AXFocusedWindow") else { return "AXFocusedWindow absent for candidate" }
    // フォーカスが候補自身のパネル、またはそのファイル選択シートにあること（他のウィンドウではないこと）
    let fwEl = fw as! AXUIElement
    guard axs(fwEl, "AXTitle") == "ShortNote" || axs(fwEl, "AXRole") == "AXSheet" else { return "focused window is not the panel (role=\(axs(fwEl, "AXRole")) title=\(axs(fwEl, "AXTitle")))" }
    return nil
}
func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
    for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!; e.flags = flags; e.post(tap: .cghidEventTap); usleep(20_000) }
    usleep(250_000)
}

// ================= run =================
makeImage("\(work)/teal.png", NSColor(deviceRed: 0, green: 0.8, blue: 0.85, alpha: 1))
makeImage("\(work)/red.png", NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))

let userPB = NSPasteboard.general.string(forType: .string)
let prevFront = NSWorkspace.shared.frontmostApplication
let outDir = "/tmp/shortnote"   // アプリ固定の書き出し先。ハーネスは自分が起動して生じたファイルだけを読む
let before = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? [])
let dragsrcBin = "\(work)/dragsrc"
let dragsrcBuild = sh(["swiftc", "-swift-version", "5", "scripts/native-dragsrc.swift", "-o", dragsrcBin])
let dragsrcOK = dragsrcBuild.0 == 0
if !dragsrcOK { print("note: native-dragsrc did not compile; D1/M1-M3 will be blocked: \(dragsrcBuild.1.prefix(200))") }

FileManager.default.createFile(atPath: "\(work)/cand.log", contents: nil, attributes: [.posixPermissions: 0o600])
// ---- 設定の隔離：キャンバスサイズの保存先（候補の bundle ID の UserDefaults）----
// 実行前に標準（960 x 640）へそろえ、終了時に元の値へ戻す。bundle ID が読めなければ、設定のケースは blocked にする。
let infoPlistPath = URL(fileURLWithPath: buildExe).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist").path
let bundleId = sh(["plutil", "-extract", "CFBundleIdentifier", "raw", infoPlistPath]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let bundleIdOK = !bundleId.isEmpty && !bundleId.contains(" ") && bundleId.contains(".")
/// 候補が受けるソケット（SPEC §3.7）。候補の bundle ID ごとに別なので、本番のものとは混ざらない。終了時に、このファイルだけを消す。
let agentSocketPath = NSHomeDirectory() + "/Library/Application Support/ShortNote/agent-\(bundleId).sock"
// 同じ bundle ID の常駐があると、起動が転送され（候補が出ない）、保存したサイズも本番のものと混ざる。scripts/e2e.sh は bundle ID を変えたコピーで実行する。
if bundleIdOK, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
    print("blocked: an instance with bundle id \(bundleId) is already running; it would receive the launch and its saved canvas size would be touched.\nUse scripts/e2e.sh (re-signed copy with another bundle id), or quit that instance first (a stale candidate left by a crashed run counts too: stop it by its recorded PID).")
    exit(77)
}
func readDefault(_ k: String) -> String? { let r = sh(["defaults", "read", bundleId, k]); return r.0 == 0 ? r.1.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
let origDefaults: [String: String?] = bundleIdOK ? ["canvasWidthPx": readDefault("canvasWidthPx"), "canvasHeightPx": readDefault("canvasHeightPx")] : [:]
if bundleIdOK { sh(["defaults", "write", bundleId, "canvasWidthPx", "-int", "960"]); sh(["defaults", "write", bundleId, "canvasHeightPx", "-int", "640"]) }
// ショートカットの保存先も隔離する。実行前の値を控え、実行前に消し、終了時に元へ戻す（canvas のサイズと同じ扱い）。
// 値は Data なので、`defaults export` の plist から取り、`-data` の 16 進で書き戻す。
func readKeyBindingsData() -> Data? {
    let r = sh(["defaults", "export", bundleId, "-"])
    guard r.0 == 0, let d = r.1.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
    return plist["keyBindings"] as? Data
}
let origKeyBindings: Data? = bundleIdOK ? readKeyBindingsData() : nil
if bundleIdOK { sh(["defaults", "delete", bundleId, "keyBindings"]) }
let proc = Process(); proc.executableURL = URL(fileURLWithPath: buildExe); proc.arguments = ["\(work)/teal.png"]
proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null"); proc.standardError = FileHandle(forWritingAtPath: "\(work)/cand.log") ?? FileHandle.nullDevice
try proc.run()
let pid = proc.processIdentifier
let startTime = sh(["ps", "-p", "\(pid)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let exePath = sh(["ps", "-p", "\(pid)", "-o", "comm="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
print("candidate pid=\(pid) start='\(startTime)' exe=\(exePath)")
rec("C0 candidate identity", exePath == buildExe ? "pass" : "fail", "pid \(pid), exe==build artifact: \(exePath == buildExe)")

/// 記録した PID だけを（起動時刻と実行ファイルを照合して）後片付けし、結果を書き出して終了する。
func finish() -> Never {
    // キャンバスサイズの設定を、実行前の状態へ戻す（ユーザーの設定を残さない）
    if bundleIdOK { for (k, v) in origDefaults { if let v { sh(["defaults", "write", bundleId, k, "-int", v]) } else { sh(["defaults", "delete", bundleId, k]) } } }
    if bundleIdOK {
        sh(["defaults", "delete", bundleId, "keyBindings"])
        if let d = origKeyBindings { sh(["defaults", "write", bundleId, "keyBindings", "-data", d.map { String(format: "%02x", $0) }.joined()]) }
    }
    if let pf = prevFront, pf.processIdentifier != pid { pf.activate(options: []) }
    if let u = userPB { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
    let psStart = sh(["ps", "-p", "\(pid)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    let psExe = sh(["ps", "-p", "\(pid)", "-o", "comm="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    if psStart == startTime && psExe == exePath { kill(pid, SIGTERM); _ = wait(3) { !proc.isRunning } }
    print("cleanup: terminated pid \(pid) (cleanup only, not a quit test); still running=\(proc.isRunning)")
    if bundleIdOK { unlink(agentSocketPath) }
    let sha = sh(["shasum", "-a", "256", buildExe]).1.split(separator: " ").first.map(String.init) ?? "?"
    let report: [String: Any] = [
        "schema_version": 1, "executable": buildExe, "binary_sha256": sha,
        "finished_at": ISO8601DateFormatter().string(from: Date()),
        "checks": results.map { ["id": $0.0, "status": $0.1, "observed": $0.2] },
    ]
    let path = "\(work)/report.json"
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
    print("\n==== summary ====")
    for (id, v, _) in results { print("\(v.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) \(id)") }
    print("report: \(path)")
    exit(results.contains { $0.1 == "fail" } ? 1 : results.contains { $0.1 == "blocked" } ? 77 : 0)
}

let app = AXUIElementCreateApplication(pid)

/// キャンバスの画面上の枠（左上原点）。Accessibility の「キャンバス」グループから実測する。
func canvasFrame(_ root: AXUIElement? = nil) -> CGRect? {
    guard let g = collect(root ?? app, { axs($0, "AXRole") == "AXGroup" && axs($0, "AXDescription") == "キャンバス" }).first,
          let pv = ax(g, "AXPosition"), let sv = ax(g, "AXSize") else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
var win: [String: Any]? = nil
_ = wait(6) { win = candWindow(pid); return win != nil }
guard let w = win else { rec("C1 panel appears", "fail", "no on-screen 'ShortNote' window for pid \(pid) within 6s"); finish() }
let wb = bounds(w); let wid = (w[kCGWindowNumber as String] as! NSNumber).intValue
rec("C1 panel appears on launch with image arg", "pass", "window \(wid) bounds \(wb) layer \(w[kCGWindowLayer as String] ?? "?")")
let policy = NSRunningApplication(processIdentifier: pid)?.activationPolicy
rec("C2 no Dock presence", policy == .accessory ? "pass" : "fail", "activationPolicy=\(String(describing: policy?.rawValue)) (accessory=1)")

func capturePanel(_ name: String) -> NSBitmapImageRep? {
    guard let cw = candWindow(pid), let id = (cw[kCGWindowNumber as String] as? NSNumber)?.intValue else { return nil }
    sh(["screencapture", "-x", "-o", "-l\(id)", "\(work)/\(name).png"]); return load("\(work)/\(name).png")
}
if let cap = capturePanel("panel1") {
    let cw0 = candWindow(pid).map { bounds($0) } ?? wb
    var cf0 = CGRect.zero; _ = wait(5) { if let c = canvasFrame() { cf0 = c; return true }; return false }
    let s = Double(cap.pixelsWide) / Double(cw0.width)
    let p = px(cap, Int((cf0.minX - cw0.minX + 360) * s), Int((cf0.minY - cw0.minY + 100) * s))
    rec("C3 CLI image shown on canvas (window capture)", isTeal(p) ? "pass" : "fail", "canvas px rgb=\(p.r),\(p.g),\(p.b); capture \(cap.pixelsWide)x\(cap.pixelsHigh)")
} else { rec("C3 CLI image shown on canvas", "blocked", "window capture failed") }

// AX: wait for tree
var copyBtn: AXUIElement? = nil
_ = wait(6) { copyBtn = collect(app) { axs($0, "AXRole") == "AXButton" && ["パスをコピー", "コピーしました"].contains(axs($0, "AXTitle")) }.first; return copyBtn != nil }
guard let copy = copyBtn else { rec("AX copy button", "fail", "not found\n" + dumpTree(app)); finish() }
let boxes = collect(app) { axs($0, "AXRole") == "AXCheckBox" && axs($0, "AXTitle") == "背景透過" }
let radios = collect(app) { axs($0, "AXRole") == "AXRadioButton" }.sorted { (ax($0, "AXPosition").flatMap { v in var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p.x } ?? 0) < (ax($1, "AXPosition").flatMap { v in var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p.x } ?? 0) }
let sliders = collect(app) { axs($0, "AXRole") == "AXSlider" }
rec("C4 AX controls reachable", (boxes.count == 1 && radios.count == 6 && sliders.count == 1) ? "pass" : "fail",
    "checkbox=\(boxes.count) toolRadios=\(radios.count) slider=\(sliders.count); tool labels=\(radios.map { "t='\(axs($0, "AXTitle"))' d='\(axs($0, "AXDescription"))' h='\(axs($0, "AXHelp"))'" })")

func export() -> String? {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("SNV-SENTINEL", forType: .string)
    // re-find (title flips for 1.2s)
    guard let b = collect(app, { axs($0, "AXRole") == "AXButton" && ["パスをコピー", "コピーしました"].contains(axs($0, "AXTitle")) }).first,
          AXUIElementPerformAction(b, kAXPressAction as CFString) == .success else { return nil }
    var path: String? = nil
    _ = wait(5) { let s = NSPasteboard.general.string(forType: .string); if let s, s != "SNV-SENTINEL" { path = s; return true }; return false }
    return path
}
let C = canvasFrame().map { CGPoint(x: $0.minX, y: $0.minY) } ?? CGPoint(x: wb.origin.x + 12, y: wb.origin.y + 61)   // キャンバスの左上（画面座標）。Accessibility の実測
func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: C.x + x, y: C.y + y) }

// baseline export
guard let p0 = export(), let r0 = load(p0) else { rec("C5 copy path -> PNG", "fail", "no path on pasteboard / unreadable"); finish() }
let newFile = !before.contains((p0 as NSString).lastPathComponent)
rec("C5 copy button puts a valid PNG path on clipboard", (r0.pixelsWide == 960 && r0.pixelsHigh == 640 && newFile && p0.hasPrefix(outDir)) ? "pass" : "fail",
    "path=\(p0) \(r0.pixelsWide)x\(r0.pixelsHigh) (expect 960x640 = canvas 480x320 pt x 2) newFile=\(newFile)")
let base = (isTeal(at(r0, 360, 30)), isTeal(at(r0, 370, 100)), isTeal(at(r0, 370, 220)), at(r0, 240, 3))
rec("C5b baseline export matches canvas (teal image, white letterbox)", (base.0 && base.1 && base.2 && base.3.r > 0.95 && base.3.a > 0.95) ? "pass" : "fail", "teal=\(base.0),\(base.1),\(base.2) letterbox=\(base.3)")

// pen
if drag(line(pt(280, 30), pt(440, 30)), pid: pid), let p = export(), let r = load(p) {
    let d = darkest(r, 360, 30); let t = thickness(r, col: 360, around: 30)
    rec("C6 pen stroke drawn via pointer", (isDark(d) && p != p0) ? "pass" : "fail", "darkest@(360,30) lum=\(d.lum) thicknessPx@size4=\(t) newFile=\(p != p0)")
    // brush size
    if let sl = sliders.first, AXUIElementSetAttributeValue(sl, "AXValue" as CFString, 20 as CFNumber) == .success,
       drag(line(pt(280, 280), pt(440, 280)), pid: pid), let p2 = export(), let r2 = load(p2) {
        let t2 = thickness(r2, col: 360, around: 280)
        rec("C7 brush size slider changes stroke width", t2 > t * 3 ? "pass" : "fail", "size4 thickness=\(t)px, size20 thickness=\(t2)px (expected ~5x)")
        _ = AXUIElementSetAttributeValue(sl, "AXValue" as CFString, 4 as CFNumber)
    } else { rec("C7 brush size slider", "blocked", "could not set slider / drag guard refused") }
} else { rec("C6 pen stroke", "blocked", "pointer guard refused (hit target not candidate) or export failed") }

// shapes
/// ツールバーのセグメントの番号（左から）。SPEC §4 の並び：ペン／直線／円／四角／文字／移動。キーの番号（1〜6）とは別。
enum Seg { static let pen = 0, line = 1, ellipse = 2, rect = 3, text = 4, move = 5 }
func selectTool(_ i: Int) -> Bool { guard radios.count == 6, AXUIElementPerformAction(radios[i], kAXPressAction as CFString) == .success else { return false }
    return wait(2) { (ax(radios[i], "AXValue") as? NSNumber)?.intValue == 1 } }
if selectTool(Seg.ellipse), drag(line(pt(300, 60), pt(440, 140)), pid: pid), let p = export(), let r = load(p) {
    let edge = darkest(r, 300, 100), mid = at(r, 370, 100)
    rec("C8 ellipse tool (drag sets size)", (isDark(edge) && isTeal(mid)) ? "pass" : "fail", "edge lum=\(edge.lum) interior teal=\(isTeal(mid))")
} else { rec("C8 ellipse tool", "blocked", "tool select / drag guard failed") }
var rectPath = ""
if selectTool(Seg.rect), drag(line(pt(300, 170), pt(440, 270)), pid: pid), let p = export(), let r = load(p) {
    rectPath = p
    let edge = darkest(r, 300, 220), mid = at(r, 370, 220)
    rec("C9 rectangle tool (drag sets size)", (isDark(edge) && isTeal(mid)) ? "pass" : "fail", "edge lum=\(edge.lum) interior teal=\(isTeal(mid))")
} else { rec("C9 rectangle tool", "blocked", "tool select / drag guard failed") }

// undo / redo (keyboard — guarded)
func rectEdgeDark() -> Bool? { guard let p = export(), let r = load(p) else { return nil }; return isDark(darkest(r, 300, 220)) }
func ellipseEdgeDark() -> Bool? { guard let p = export(), let r = load(p) else { return nil }; return isDark(darkest(r, 300, 100)) }
if let why = keyGuard(pid, app) {
    for id in ["C10 Cmd+Z undo", "C11 Cmd+Shift+Z redo", "C12 Ctrl+Z undo", "C13 Ctrl+Shift+Z redo", "C14 Esc hides panel"] { rec(id, "blocked", "keyboard guard: \(why)") }
} else {
    key(6, .maskCommand);                       rec("C10 Cmd+Z undo (last item = rectangle)", (rectEdgeDark() == false && ellipseEdgeDark() == true) ? "pass" : "fail", "rect edge removed, ellipse kept")
    key(6, [.maskCommand, .maskShift]);         rec("C11 Cmd+Shift+Z redo", rectEdgeDark() == true ? "pass" : "fail", "rect edge restored")
    key(6, .maskControl);                       rec("C12 Ctrl+Z undo", rectEdgeDark() == false ? "pass" : "fail", "rect edge removed")
    key(6, [.maskControl, .maskShift]);         rec("C13 Ctrl+Shift+Z redo", rectEdgeDark() == true ? "pass" : "fail", "rect edge restored")
}

// transparency
if let box = boxes.first, AXUIElementPerformAction(box, kAXPressAction as CFString) == .success,
   wait(2, { (ax(box, "AXValue") as? NSNumber)?.intValue == 1 }), let p = export(), let r = load(p) {
    let corner = at(r, 240, 3), ctr = at(r, 370, 100), stroke = darkest(r, 360, 30)
    rec("C15 transparent export (alpha PNG)", (corner.a < 0.02 && ctr.a > 0.98 && isTeal(ctr) && isDark(stroke)) ? "pass" : "fail", "letterbox alpha=\(corner.a) image alpha=\(ctr.a) stroke lum=\(stroke.lum) alpha=\(stroke.a)")
    _ = AXUIElementPerformAction(box, kAXPressAction as CFString)
    if wait(2, { (ax(box, "AXValue") as? NSNumber)?.intValue == 0 }), let p2 = export(), let r2 = load(p2) {
        let c2 = at(r2, 240, 3); rec("C16 transparency off -> opaque white", (c2.a > 0.98 && c2.r > 0.95) ? "pass" : "fail", "letterbox px=\(c2)")
    }
} else { rec("C15 transparent export", "blocked", "checkbox press / state read failed") }

// ================= new features =================
func countDark(_ r: NSBitmapImageRep, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Int {
    let s = Double(r.pixelsWide) / canvasWidthPt; var n = 0
    for y in Int(y0 * s)..<Int(y1 * s) { for x in Int(x0 * s)..<Int(x1 * s) where isDark(px(r, x, y)) { n += 1 } }
    return n
}
func isColor(_ p: Px, _ r: Double, _ g: Double, _ b: Double) -> Bool { abs(p.r - r) < 0.12 && abs(p.g - g) < 0.12 && abs(p.b - b) < 0.12 && p.a > 0.95 }
func click(_ p: CGPoint) -> Bool { guard hitOwner(p) == pid else { print("   guard refused click at \(p): front-most owner=\(String(describing: hitOwner(p))) want \(pid)"); return false }; post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p); usleep(250_000); return true }
func typeUnicode(_ s: String) {
    for unit in s.utf16 {
        var u = [unit]
        for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!; e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u); e.post(tap: .cghidEventTap); usleep(25_000) }
    }
    usleep(300_000)
}
func editorAreas() -> [AXUIElement] { collect(app) { axs($0, "AXRole") == "AXTextArea" } }
func exportImg() -> NSBitmapImageRep? { export().flatMap { load($0) } }

// ---- 文字: 入力 -> Return で確定 ----
if let why = keyGuard(pid, app) {
    for id in ["T1 text editor opens", "T2 typed text committed (Return)", "T3 Esc cancels editing without hiding panel"] { rec(id, "blocked", "keyboard guard: \(why)") }
} else {
    if selectTool(Seg.text), click(pt(20, 20)) {
        let fo = ax(app, "AXFocusedUIElement").map { axs($0 as! AXUIElement, "AXRole") } ?? "<none>"
        rec("T1 text tool opens inline editor on click", editorAreas().count == 1 ? "pass" : "fail", "AXTextArea count=\(editorAreas().count) focusedRole=\(fo) frontmostIsCandidate=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        for kc: CGKeyCode in [0, 11, 8] { key(kc, []) }   // real keycodes a b c
        let typedKeys = editorAreas().first.map { axs($0, "AXValue") } ?? "<none>"
        rec("T2a real keystrokes reach the editor (IME composition allowed)", (!typedKeys.isEmpty && typedKeys != "<none>") ? "pass" : "fail", "AXValue after keycodes a,b,c = '\(typedKeys)' (with a Japanese IME active this is kana + latin)")
        if let ta = editorAreas().first { _ = AXUIElementSetAttributeValue(ta, "AXValue" as CFString, "ABC指示" as CFString) }
        let typed = editorAreas().first.map { axs($0, "AXValue") } ?? "<none>"
        key(36, [])
        let closed = wait(2) { editorAreas().isEmpty }
        if let r = exportImg() {
            let n = countDark(r, 20, 20, 170, 52), left = countDark(r, 0, 20, 16, 52)
            rec("T2 typed text (latin+Japanese) committed with Return and exported", (typed == "ABC指示" && closed && n > 150 && left == 0) ? "pass" : "fail",
                "editor value='\(typed)' editorClosed=\(closed) darkPx in text box=\(n) (need>150) darkPx left of click=\(left)")
        } else { rec("T2", "blocked", "export failed") }
    } else { rec("T1 text tool", "blocked", "tool select / click guard failed") }
    if selectTool(Seg.text), keyGuard(pid, app) == nil, click(pt(20, 70)) {
        typeUnicode("ZZZ"); key(53, [])
        let closed = wait(2) { editorAreas().isEmpty }
        if let r = exportImg() {
            let n = countDark(r, 18, 70, 150, 100)
            rec("T3 Esc cancels editing without hiding panel", (closed && candWindow(pid) != nil && n == 0) ? "pass" : "fail",
                "editorClosed=\(closed) panelStillVisible=\(candWindow(pid) != nil) darkPx=\(n)")
        }
    }
}

// ---- 画像貼り付け (Cmd+V) ----
let redImg = NSImage(contentsOfFile: "\(work)/red.png")!
NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([redImg])
if keyGuard(pid, app) == nil {
    key(9, .maskCommand)
    if let r = exportImg() {
        let ctr = at(r, 240, 160), inside = at(r, 100, 160), outside = at(r, 50, 160), above = at(r, 240, 40)
        rec("P1 Cmd+V pastes clipboard image, centered, fit to 70%", (isColor(ctr, 0.9, 0.1, 0.1) && isColor(inside, 0.9, 0.1, 0.1) && isTeal(outside) && isTeal(above)) ? "pass" : "fail",
            "center red=\(isColor(ctr, 0.9, 0.1, 0.1)) x=100 red=\(isColor(inside, 0.9, 0.1, 0.1)) x=50 teal=\(isTeal(outside)) y=40 teal=\(isTeal(above))")
    }
} else { rec("P1 Cmd+V paste", "blocked", "keyboard guard failed") }

func isMag(_ p: Px) -> Bool { p.r > 0.7 && p.b > 0.7 && p.g < 0.4 && p.a > 0.95 }   // measured magenta after colour management: 0.92,0.23,0.91
// ---- 画像ドラッグ&ドロップ（自分で起動したドラッグ元プロセス native-dragsrc を使う。他アプリは使わない）----
if dragsrcOK {
makeImage("\(work)/magenta.png", NSColor(deviceRed: 0.9, green: 0, blue: 0.9, alpha: 1))
let resultPath = "\(work)/dragsrc.result"; try? FileManager.default.removeItem(atPath: resultPath)
let srcProc = Process(); srcProc.executableURL = URL(fileURLWithPath: dragsrcBin)
srcProc.arguments = ["\(wb.minX - 150)", "\(wb.minY + 120)", "120", "80", "\(work)/magenta.png", resultPath]
try srcProc.run()
let srcPid = srcProc.processIdentifier
let srcStart = sh(["ps", "-p", "\(srcPid)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let sp = CGPoint(x: wb.minX - 150 + 60, y: wb.minY + 120 + 40), dp = pt(200, 200)
_ = wait(5) { hitOwner(sp) == srcPid }
if hitOwner(sp) == srcPid, hitOwner(dp) == pid {
    post(.mouseMoved, sp); post(.leftMouseDown, sp); usleep(200_000)
    for i in 1...3 { post(.leftMouseDragged, CGPoint(x: sp.x + CGFloat(i) * 6, y: sp.y)); usleep(60_000) }
    for p in line(CGPoint(x: sp.x + 18, y: sp.y), dp, steps: 30) { post(.leftMouseDragged, p); usleep(30_000) }
    for _ in 0..<4 { post(.leftMouseDragged, CGPoint(x: dp.x + 1, y: dp.y)); usleep(100_000) }
    post(.leftMouseUp, dp)
    let got = wait(5) { FileManager.default.fileExists(atPath: resultPath) }
    let op = (try? String(contentsOfFile: resultPath, encoding: .utf8)) ?? "none"
    _ = capturePanel("afterdrop")
    if let r = exportImg() {
        let ctr = at(r, 200, 200), dropOnly = at(r, 60, 290), notCentered = at(r, 400, 100)
        let mag = { (p: Px) in isMag(p) }
        rec("D1 dropped image added at drop location", (got && op == "1" && mag(ctr) && mag(dropOnly) && !mag(notCentered)) ? "pass" : "fail",
            "source reported operation=\(op) (copy=1) drop-centre magenta=\(mag(ctr)) (60,290) magenta=\(mag(dropOnly)) (400,100) magenta=\(mag(notCentered)) [must be false]")
    }
} else { rec("D1 drag & drop", "blocked", "hit-target guard refused: src hit=\(String(describing: hitOwner(sp))) (want \(srcPid)) drop hit=\(String(describing: hitOwner(dp))) (want \(pid))") }
if sh(["ps", "-p", "\(srcPid)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines) == srcStart { kill(srcPid, SIGTERM) }
} else { rec("D1 drag & drop", "blocked", "scripts/native-dragsrc.swift did not compile (run from the repository root)") }

// ---- 移動ツール / Undo ----
if !dragsrcOK { rec("M1 move tool", "blocked", "needs the D1 image (drag source did not compile)") } else if selectTool(Seg.move), drag(line(pt(200, 200), pt(260, 170)), pid: pid), let r = exportImg() {
    let moved = at(r, 400, 100), old = at(r, 60, 290)
    rec("M1 move tool drags topmost image", (isMag(moved) && !isMag(old)) ? "pass" : "fail", "(400,100) magenta=\(isMag(moved)) (60,290) magenta=\(isMag(old))")
} else { rec("M1 move tool", "blocked", "tool select / pointer guard failed") }
if !dragsrcOK {
    rec("M2/M3 undo", "blocked", "needs the D1 image (drag source did not compile)")
} else if keyGuard(pid, app) == nil {
    key(6, .maskCommand)
    if let r = exportImg() { rec("M2 Cmd+Z undoes the move", (isMag(at(r, 60, 290)) && !isMag(at(r, 400, 100))) ? "pass" : "fail", "image back at drop location") }
    key(6, .maskCommand)
    if let r = exportImg() { rec("M3 Cmd+Z undoes the dropped image", (!isMag(at(r, 200, 200)) && isColor(at(r, 240, 160), 0.9, 0.1, 0.1)) ? "pass" : "fail", "pasted red image remains") }
} else { rec("M2/M3 undo", "blocked", "keyboard guard failed") }

// ---- ウィンドウのリサイズ・最大化（A12）----
func axWindow() -> AXUIElement? { (ax(app, "AXWindows") as? [AXUIElement])?.first }
func axSize(_ e: AXUIElement) -> CGSize? { guard let v = ax(e, "AXSize") else { return nil }; var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); return s }
func setAXSize(_ e: AXUIElement, _ w: CGFloat, _ h: CGFloat) { var s = CGSize(width: w, height: h); if let v = AXValueCreate(.cgSize, &s) { _ = AXUIElementSetAttributeValue(e, "AXSize" as CFString, v) } }
func waitCanvas(_ pred: (CGRect) -> Bool) -> CGRect? { var r: CGRect? = nil; _ = wait(4) { if let c = canvasFrame(), pred(c) { r = c; return true }; return false }; return r }
if let aw = axWindow(), let c0 = canvasFrame(), let w0 = axSize(aw) {
    setAXSize(aw, 300, 200); usleep(600_000)
    let cMin = canvasFrame() ?? c0
    rec("Z1 window cannot shrink below the canvas minimum", (abs(cMin.width - 480) < 1 && abs(cMin.height - 320) < 1) ? "pass" : "fail", "after asking for 300x200: canvas \(Int(cMin.width))x\(Int(cMin.height)) (the minimum is exactly 480x320; a wider toolbar would push it up)")

    setAXSize(aw, w0.width + 240, w0.height + 160)
    if let c1 = waitCanvas({ $0.width > c0.width + 200 }) {
        canvasWidthPt = Double(c1.width)
        if let r = exportImg() {
            let penKept = isDark(darkest(r, 360, 30))
            let aspectOK = abs((Double(r.pixelsWide) / Double(max(1, r.pixelsHigh))) / Double(c1.width / c1.height) - 1) < 0.01
            let exact2x = r.pixelsWide == Int(c1.width * 2) && r.pixelsHigh == Int(c1.height * 2)
            let corner = at(r, Double(c1.width) - 10, Double(c1.height) - 10)
            rec("Z2 growing the window grows the canvas; content stays at the top-left; export is exactly 2x the canvas", (penKept && aspectOK && exact2x && corner.a > 0.95 && corner.r > 0.95 && corner.g > 0.95) ? "pass" : "fail",
                "canvas \(Int(c0.width))x\(Int(c0.height)) -> \(Int(c1.width))x\(Int(c1.height)); export \(r.pixelsWide)x\(r.pixelsHigh) (exactly 2x=\(exact2x)); pen stroke kept at same position=\(penKept); aspect matches=\(aspectOK); new area is white=\(corner.r > 0.95)")
        } else { rec("Z2", "blocked", "export failed") }

        // 最大化（ズームボタン）
        if let zb = ax(aw, "AXZoomButton") {
            _ = AXUIElementPerformAction(zb as! AXUIElement, kAXPressAction as CFString)
            if let c2 = waitCanvas({ $0.width > c1.width + 100 || $0.height > c1.height + 100 }) {
                usleep(500_000)
                let cz = canvasFrame() ?? c2
                canvasWidthPt = Double(cz.width)
                if let r = exportImg() {
                    let longest = max(r.pixelsWide, r.pixelsHigh)
                    let penKept = isDark(darkest(r, 360, 30))
                    let wz = candWindow(pid).map { bounds($0) } ?? .zero
                    let fills = NSScreen.screens.contains { abs($0.visibleFrame.width - wz.width) < 3 && abs($0.visibleFrame.height - wz.height) < 3 }   // ウィンドウが、いずれかの画面の表示領域いっぱいになる
                    rec("Z3 zoom button maximizes: the window fills the screen's visible area; canvas grows; export is 2x the canvas", (penKept && fills && longest <= 8192 && r.pixelsWide == Int(cz.width * 2)) ? "pass" : "fail",
                        "window \(Int(wz.width))x\(Int(wz.height)) fills a screen's visible area=\(fills); canvas \(Int(c1.width))x\(Int(c1.height)) -> \(Int(cz.width))x\(Int(cz.height)); export \(r.pixelsWide)x\(r.pixelsHigh); pen stroke kept=\(penKept). (8192 px cap itself is not exercised: 2x of this screen stays below it)")
                }
                _ = AXUIElementPerformAction(zb as! AXUIElement, kAXPressAction as CFString)   // もとの大きさへ
                let back = waitCanvas({ abs($0.width - c1.width) < 2 && abs($0.height - c1.height) < 2 })   // 最大化の前の大きさに、実際に戻ること
                rec("Z4 zoom button again restores the size it had before maximizing", back != nil ? "pass" : "fail", "expected canvas \(Int(c1.width))x\(Int(c1.height)); after second press: \(canvasFrame().map { "\(Int($0.width))x\(Int($0.height))" } ?? "unavailable")")
            } else { rec("Z3 zoom button maximizes", "fail", "canvas did not grow after AXPress on the zoom button (zoom button enabled=\(String(describing: ax(zb as! AXUIElement, "AXEnabled"))))") }
        } else { rec("Z3 zoom button maximizes", "fail", "the window has no AXZoomButton") }
    } else { rec("Z2 growing the window grows the canvas", "fail", "canvas did not grow after setting AXSize") }
    setAXSize(aw, w0.width, w0.height); _ = waitCanvas({ abs($0.width - c0.width) < 2 }); canvasWidthPt = 480
} else { rec("Z1-Z4 window resize / maximize", "blocked", "could not read the window or canvas through Accessibility") }

// ---- 実際のマウスで、ウィンドウの角をドラッグして大きさを変える（A12）。AX でサイズを設定する Z1〜Z4 とは別の経路（枠のドラッグ）----
// 掴むのは、自分のウィンドウの右下の角の内側（mouseDown が自分のウィンドウに入ることを確かめる）。ドラッグの間は、ボタンを押した窓にイベントが届くので、動かす先の画面の位置は確かめない。
func cornerDrag(_ from: CGPoint, _ to: CGPoint) -> Bool {
    guard hitOwner(from) == pid else { print("   guard refused corner mouseDown at \(from): front-most owner=\(String(describing: hitOwner(from))) want \(pid)"); return false }
    post(.mouseMoved, from); post(.leftMouseDown, from)
    for p in line(from, to, steps: 30).dropFirst() { post(.leftMouseDragged, p) }
    post(.leftMouseUp, to); usleep(400_000)
    return true
}
let resizeIds = ["Z5 dragging the window's bottom-right corner with the real mouse grows the canvas", "Z6 dragging the corner back shrinks the canvas to its previous size"]
if let c0 = canvasFrame(), let wb0 = candWindow(pid).map({ bounds($0) }) {
    let grab = CGPoint(x: wb0.maxX - 3, y: wb0.maxY - 3)
    if cornerDrag(grab, CGPoint(x: grab.x + 120, y: grab.y + 80)) {
        let grown = waitCanvas { $0.width > c0.width + 60 && $0.height > c0.height + 40 }
        let wb1 = candWindow(pid).map { bounds($0) } ?? .zero
        rec(resizeIds[0], grown != nil ? "pass" : "fail", "window \(Int(wb0.width))x\(Int(wb0.height)) -> \(Int(wb1.width))x\(Int(wb1.height)); canvas \(Int(c0.width))x\(Int(c0.height)) -> \(grown.map { "\(Int($0.width))x\(Int($0.height))" } ?? (canvasFrame().map { "\(Int($0.width))x\(Int($0.height))" } ?? "unavailable")) (a drag of +120,+80 pt from the corner at \(Int(grab.x)),\(Int(grab.y)))")
        if grown != nil {
            let grab2 = CGPoint(x: wb1.maxX - 3, y: wb1.maxY - 3)
            if cornerDrag(grab2, CGPoint(x: grab2.x - 120, y: grab2.y - 80)) {
                let back = waitCanvas { abs($0.width - c0.width) < 4 && abs($0.height - c0.height) < 4 }
                rec(resizeIds[1], back != nil ? "pass" : "fail", "canvas after dragging back: \(canvasFrame().map { "\(Int($0.width))x\(Int($0.height))" } ?? "unavailable") (expect about \(Int(c0.width))x\(Int(c0.height)))")
            } else { rec(resizeIds[1], "blocked", "the corner mouseDown guard refused") }
        } else { rec(resizeIds[1], "blocked", "depends on Z5") }
    } else { rec(resizeIds[0], "blocked", "the corner mouseDown guard refused"); rec(resizeIds[1], "blocked", "depends on Z5") }
} else { for id in resizeIds { rec(id, "blocked", "could not read the canvas or the window bounds") } }

func isCanvas(_ w: Double, _ h: Double) -> (CGRect) -> Bool { { abs($0.width - w) < 1 && abs($0.height - h) < 1 } }
// ---- キャンバスサイズの設定（A13）：メニューバーのメニュー・保存・書き出しのピクセル数 ----
func statusMenuBar() -> AXUIElement? { (ax(app, "AXExtrasMenuBar") ?? ax(app, "AXMenuBar")).map { $0 as! AXUIElement } }
func menuItem(_ prefix: String) -> AXUIElement? { statusMenuBar().flatMap { bar in collect(bar) { axs($0, "AXRole") == "AXMenuItem" && axs($0, "AXTitle").hasPrefix(prefix) }.first } }
func menuMark(_ prefix: String) -> String { menuItem(prefix).map { axs($0, "AXMenuItemMarkChar") } ?? "?" }
func pressMenu(_ prefix: String) -> Bool { guard let i = menuItem(prefix) else { return false }; return AXUIElementPerformAction(i, kAXPressAction as CFString) == .success }
func dialogWindow() -> AXUIElement? { ((ax(app, "AXWindows") as? [AXUIElement]) ?? []).first { axs($0, "AXTitle") != "ShortNote" } }
func axX(_ e: AXUIElement) -> CGFloat { guard let v = ax(e, "AXPosition") else { return 0 }; var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p.x }
/// 「数値で指定…」のダイアログに値を入れて「設定」を押す。ダイアログは runModal なので、メニューを押す呼び出しは戻らない。タイムアウトを短くして先へ進む。
func runCustomSize(_ w: String, _ h: String) -> Bool {
    AXUIElementSetMessagingTimeout(app, 1.0); _ = pressMenu("数値で指定"); AXUIElementSetMessagingTimeout(app, 0)
    var dlg: AXUIElement? = nil; _ = wait(4) { dlg = dialogWindow(); return dlg != nil }
    guard let d = dlg else { return false }
    let fields = collect(d) { axs($0, "AXRole") == "AXTextField" }.sorted { axX($0) < axX($1) }   // 左が幅、右が高さ
    guard fields.count >= 2, let ok = collect(d, { axs($0, "AXRole") == "AXButton" && axs($0, "AXTitle") == "設定" }).first else { return false }
    _ = AXUIElementSetAttributeValue(fields[0], "AXValue" as CFString, w as CFString)
    _ = AXUIElementSetAttributeValue(fields[1], "AXValue" as CFString, h as CFString)
    return AXUIElementPerformAction(ok, kAXPressAction as CFString) == .success
}
/// ステータスメニューを実際に開いて `body` を実行し、閉じる。閉じたメニューの表示は、開いたときに更新される（menuNeedsUpdate）ので、チェックの確認は開いて読む。
/// メニューを押す呼び出しは、メニューが閉じるまで戻らない。タイムアウトを短くして先へ進む。
func withMenuOpen<T>(_ body: () -> T) -> T {
    guard let bar = statusMenuBar(), let item = (ax(bar, "AXChildren") as? [AXUIElement])?.first else { return body() }
    AXUIElementSetMessagingTimeout(app, 1.0); _ = AXUIElementPerformAction(item, kAXPressAction as CFString); AXUIElementSetMessagingTimeout(app, 0)
    usleep(600_000)
    let result = body()
    if let menu = (ax(item, "AXChildren") as? [AXUIElement])?.first { _ = AXUIElementPerformAction(menu, "AXCancel" as CFString) }
    usleep(300_000)
    return result
}
if !bundleIdOK {
    rec("S1-S5 canvas size setting", "blocked", "could not read the candidate's bundle identifier from its Info.plist")
} else {
    let (s1ok, s1marks) = withMenuOpen { (menuMark("960 × 640") == "✓" && menuItem("1280 × 720") != nil, "960x640=\(menuMark("960 × 640")) 1280x720=\(menuMark("1280 × 720"))") }
    rec("S1 the menu lists the presets and checks the saved size (960 x 640)", s1ok ? "pass" : "fail", "marks (menu opened): \(s1marks)")

    if pressMenu("1280 × 720"), waitCanvas(isCanvas(640, 360)) != nil {
        canvasWidthPt = 640
        let r = exportImg()
        let exact = r.map { $0.pixelsWide == 1280 && $0.pixelsHigh == 720 } ?? false
        let saved = readDefault("canvasWidthPx") == "1280" && readDefault("canvasHeightPx") == "720"
        let (marked, marks) = withMenuOpen { (menuMark("1280 × 720") == "✓" && menuMark("960 × 640") != "✓", "1280x720=\(menuMark("1280 × 720")) 960x640=\(menuMark("960 × 640"))") }
        rec("S2 a preset sizes the canvas; the export is exactly that many pixels; the choice is saved and checked", (exact && saved && marked) ? "pass" : "fail",
            "export \(r.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "failed") (expect 1280x720); saved=\(saved); check mark moved=\(marked) [\(marks)]")
    } else { rec("S2 a preset sizes the canvas", "fail", "the canvas did not become 640x360 pt after choosing 1280 x 720") }

    if runCustomSize("1000", "700"), waitCanvas(isCanvas(500, 350)) != nil {
        canvasWidthPt = 500
        let r = exportImg()
        let exact = r.map { $0.pixelsWide == 1000 && $0.pixelsHigh == 700 } ?? false
        let saved = readDefault("canvasWidthPx") == "1000" && readDefault("canvasHeightPx") == "700"
        let shown = withMenuOpen { menuItem("数値で指定").map { axs($0, "AXTitle").contains("1000 × 700") && axs($0, "AXMenuItemMarkChar") == "✓" } ?? false }
        rec("S3 a typed size works: canvas, export pixels, saved value, and the menu shows it", (exact && saved && shown) ? "pass" : "fail",
            "export \(r.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "failed") (expect 1000x700); saved=\(saved); menu shows the number and a check=\(shown)")
    } else { rec("S3 a typed size works", "blocked", "could not drive the custom-size dialog through Accessibility, or the canvas did not become 500x350 pt") }

    if runCustomSize("20000", "700") {
        var warn: AXUIElement? = nil; _ = wait(4) { warn = dialogWindow(); return warn != nil }
        let warned = warn != nil
        if let wn = warn, let okb = collect(wn, { axs($0, "AXRole") == "AXButton" }).first { _ = AXUIElementPerformAction(okb, kAXPressAction as CFString) }
        usleep(600_000)
        let unchanged = canvasFrame().map { abs($0.width - 500) < 1 && abs($0.height - 350) < 1 } ?? false
        let savedSame = readDefault("canvasWidthPx") == "1000" && readDefault("canvasHeightPx") == "700"
        rec("S4 a size that cannot fit is refused with a message and changes nothing", (warned && unchanged && savedSame) ? "pass" : "fail", "message shown=\(warned); canvas unchanged=\(unchanged); saved value unchanged=\(savedSame)")
    } else { rec("S4 a size that cannot fit is refused", "blocked", "could not drive the custom-size dialog through Accessibility") }

    if pressMenu("960 × 640"), waitCanvas(isCanvas(480, 320)) != nil { canvasWidthPt = 480 }
    else { rec("S5 restoring the standard size", "fail", "the canvas did not return to 480x320 pt") }
}

// ---- ファイル選択（A05）----
func sheets() -> [AXUIElement] { collect(app) { axs($0, "AXRole") == "AXSheet" } }
let pickDir = "\(work)/pick"
try? FileManager.default.createDirectory(atPath: pickDir, withIntermediateDirectories: true)
makeImage("\(pickDir)/blue.png", NSColor(deviceRed: 0.1, green: 0.1, blue: 0.9, alpha: 1))
if let why = keyGuard(pid, app) {
    for id in ["F0 Cmd+O opens the file chooser", "F1 add-image button opens the file chooser", "F2 chosen image is added"] { rec(id, "blocked", "keyboard guard: \(why)") }
} else {
    key(31, .maskCommand)
    let openedByKey = wait(4) { !sheets().isEmpty }
    rec("F0 Cmd+O opens the file chooser", openedByKey ? "pass" : "fail", "AXSheet count=\(sheets().count)")
    if openedByKey { key(53, []); _ = wait(3) { sheets().isEmpty } }

    let pickBtn = collect(app) { axs($0, "AXRole") == "AXButton" && axs($0, "AXDescription") == "画像を追加" }.first
    if let pb = pickBtn, AXUIElementPerformAction(pb, kAXPressAction as CFString) == .success {
        let opened = wait(4) { !sheets().isEmpty }
        rec("F1 add-image button opens the file chooser", opened ? "pass" : "fail", "AXSheet count=\(sheets().count)")
        if opened, keyGuard(pid, app) == nil {
            // Cmd+Shift+G で「フォルダへ移動」を開き、入力欄へ AX で青い画像のパスを入れる（キー入力より確実）。
            // Return で移動してそのファイルが選択され、もう一度 Return で開く。
            key(5, [.maskCommand, .maskShift]); _ = wait(3) { sheets().count >= 2 }; usleep(400_000)
            if let inner = sheets().last, let field = collect(inner, { axs($0, "AXRole") == "AXTextField" }).first {
                _ = AXUIElementSetAttributeValue(field, "AXValue" as CFString, "\(pickDir)/blue.png" as CFString)
            }
            usleep(400_000)
            key(36, []); _ = wait(3) { sheets().count == 1 }; usleep(700_000)   // 移動（そのファイルが選択される）
            key(36, [])                                                           // 開く
            let closed = wait(5) { sheets().isEmpty }
            if closed, let r = exportImg() {
                let ctr = at(r, canvasWidthPt / 2, 160)
                let isBlue = ctr.b > 0.7 && ctr.r < 0.35 && ctr.g < 0.4 && ctr.a > 0.95   // 色管理で G が 0.1 → 約 0.23 になる。赤（貼り付け画像）・ティール（背景）とは区別できる
                rec("F2 chosen image is added at the centre", isBlue ? "pass" : "fail", "centre px rgb=\(ctr.r),\(ctr.g),\(ctr.b) (expect blue)")
            } else {
                for _ in 0..<3 where !sheets().isEmpty { key(53, []) }
                rec("F2 chosen image is added at the centre", "blocked", "could not drive the open panel with keystrokes (sheet still open after Return)")
            }
        } else if opened { rec("F2 chosen image is added at the centre", "blocked", "keyboard guard failed after the sheet opened") }
    } else { rec("F1 add-image button opens the file chooser", "fail", "no AXButton 'add image' found or AXPress failed") }
}
// ファイル選択のシートが残っていたら閉じる（後続の撮影に写らないように）
for _ in 0..<3 where !sheets().isEmpty { key(53, []); _ = wait(2) { sheets().isEmpty } }

// second launch forwards to resident instance
let before2 = proc.isRunning
let p2 = Process(); p2.executableURL = URL(fileURLWithPath: buildExe); p2.arguments = ["\(work)/red.png"]
try p2.run(); let exited = wait(4) { !p2.isRunning }
let stillSame = sh(["ps", "-p", "\(pid)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines) == startTime
if let cap = capturePanel("panel2") {
    let cw = candWindow(pid).map { bounds($0) } ?? wb; let cf = canvasFrame() ?? .zero
    let s = Double(cap.pixelsWide) / Double(cw.width); let p = px(cap, Int((cf.minX - cw.minX + 360) * s), Int((cf.minY - cw.minY + 100) * s))
    rec("C17 2nd launch w/ path forwards to resident instance", (exited && stillSame && before2 && p.r > 0.7 && p.g < 0.3) ? "pass" : "fail", "2nd exited=\(exited) resident same start=\(stillSame) canvas rgb=\(p.r),\(p.g),\(p.b)")
}

// ---- 画像の向き：上下・左右が反転していない（画面の描画と書き出しの両方）----
func makeAsymImage(_ path: String) {
    let img = NSImage(size: NSSize(width: 800, height: 500))
    img.lockFocus()
    NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill(); NSRect(x: 0, y: 250, width: 400, height: 250).fill()    // 見た目の左上：赤
    NSColor(deviceRed: 0.95, green: 0.9, blue: 0.1, alpha: 1).setFill(); NSRect(x: 400, y: 250, width: 400, height: 250).fill() // 右上：黄
    NSColor(deviceRed: 0.1, green: 0.7, blue: 0.1, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 800, height: 250).fill()      // 下半分：緑
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
func isRedish(_ p: Px) -> Bool { p.r > 0.7 && p.g < 0.35 && p.b < 0.35 && p.a > 0.95 }
func isYellowish(_ p: Px) -> Bool { p.r > 0.7 && p.g > 0.7 && p.b < 0.4 && p.a > 0.95 }
func isGreenish(_ p: Px) -> Bool { p.g > 0.5 && p.r < 0.4 && p.b < 0.4 && p.a > 0.95 }
makeAsymImage("\(work)/asym.png")
let p4 = Process(); p4.executableURL = URL(fileURLWithPath: buildExe); p4.arguments = ["\(work)/asym.png"]
try p4.run(); _ = wait(4) { !p4.isRunning }
if let cf = waitCanvas({ _ in true }) {
    _ = wait(2) { true }; usleep(500_000)
    let W = Double(cf.width), H = Double(cf.height)
    let pts = [(W * 0.25, H * 0.3), (W * 0.75, H * 0.3), (W * 0.5, H * 0.8)]   // 左上・右上・下
    var screenOK = false
    if let cap = capturePanel("orient"), let cw = candWindow(pid).map({ bounds($0) }) {
        let s = Double(cap.pixelsWide) / Double(cw.width)
        let q = pts.map { px(cap, Int((Double(cf.minX - cw.minX) + $0.0) * s), Int((Double(cf.minY - cw.minY) + $0.1) * s)) }
        screenOK = isRedish(q[0]) && isYellowish(q[1]) && isGreenish(q[2])
    }
    canvasWidthPt = W
    var exportOK = false
    if let r = exportImg() { let q = pts.map { at(r, $0.0, $0.1) }; exportOK = isRedish(q[0]) && isYellowish(q[1]) && isGreenish(q[2]) }
    canvasWidthPt = 480
    rec("O1 background image keeps its orientation (screen drawing and export)", (screenOK && exportOK) ? "pass" : "fail", "top-left red / top-right yellow / bottom green on screen=\(screenOK), in the exported PNG=\(exportOK)")

    // 貼り付けた画像も同じ向きか（背景と同じ柄を中央に貼る。反転していれば左上が緑になる）
    NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(contentsOfFile: "\(work)/asym.png")!])
    if keyGuard(pid, app) == nil {
        key(9, .maskCommand)
        canvasWidthPt = W
        if let r = exportImg() {
            // 貼り付け画像は 70% に縮小して中央：左上の四分の一 ≈ (0.30W…0.5W, 0.17H…0.5H) の中の点
            let tl = at(r, W * 0.36, H * 0.3), tr = at(r, W * 0.64, H * 0.3), bot = at(r, W * 0.5, H * 0.8)
            rec("O2 pasted image keeps its orientation", (isRedish(tl) && isYellowish(tr) && isGreenish(bot)) ? "pass" : "fail", "pasted-image points: top-left red=\(isRedish(tl)) top-right yellow=\(isYellowish(tr)) bottom green=\(isGreenish(bot))")
        }
        canvasWidthPt = 480
    } else { rec("O2 pasted image keeps its orientation", "blocked", "keyboard guard failed") }
} else { rec("O1 image orientation", "blocked", "canvas frame unavailable") }

// ---- ショートカット（A14）：既定のキー・設定ウィンドウでの割り当て・競合・保存 ----
// 全域ホットキー（⌃⌥N）の変更は、OS 全体のキーを使うため、ここでは試さない（人の確認: SNT-001）。
func radioSelected() -> Int? { radios.firstIndex { (ax($0, "AXValue") as? NSNumber)?.intValue == 1 } }
func sliderValue() -> Double? { sliders.first.flatMap { (ax($0, "AXValue") as? NSNumber)?.doubleValue } }
func shortcutsWin() -> AXUIElement? { ((ax(app, "AXWindows") as? [AXUIElement]) ?? []).first { axs($0, "AXTitle") == "ショートカット" } }
func scElement(_ id: String) -> AXUIElement? { shortcutsWin().flatMap { w in collect(w) { axs($0, "AXIdentifier") == id }.first } }
func scText(_ id: String) -> String { scElement(id).map { axs($0, "AXValue") } ?? "?" }
func scPress(_ id: String) -> Bool { scElement(id).map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false }
func focusedTitle() -> String { (ax(app, "AXFocusedWindow")).map { axs($0 as! AXUIElement, "AXTitle") } ?? "" }
/// 設定ウィンドウにキー入力してよいか（候補が最前面で、フォーカスが設定ウィンドウ）。
func shortcutsGuard() -> String? {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
    guard wait(2, { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else { return "frontmost is not the candidate" }
    guard wait(2, { focusedTitle() == "ショートカット" }) else { return "focused window is '\(focusedTitle())', not the shortcuts window" }
    return nil
}
func openShortcuts() -> Bool { _ = pressMenu("ショートカット…"); return wait(4) { shortcutsWin() != nil } && shortcutsGuard() == nil }
func closeShortcutsAndShowPanel() {
    if let w = shortcutsWin(), let c = ax(w, "AXCloseButton") { _ = AXUIElementPerformAction(c as! AXUIElement, kAXPressAction as CFString) }
    _ = wait(2) { shortcutsWin() == nil }
    _ = pressMenu("ShortNote を開く"); _ = wait(3) { candWindow(pid) != nil }
}
/// いまのキーボード配列で、修飾キーなしで文字 `ch` を出す物理キーのキーコード。アプリの既定のキーとは別に、ハーネスが求める（アプリの解決を、そのまま信じない）。
func keyCodeProducing(_ ch: String) -> CGKeyCode? {
    guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let prop = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(prop).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return nil }
    let type = UInt32(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0)
    return withExtendedLifetime((src, data)) {
        for code in CGKeyCode(0)..<128 {
            var dead: UInt32 = 0, len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let st = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { UCKeyTranslate($0, code, UInt16(kUCKeyActionDown), 0, type, OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars) }
            if st == noErr, len > 0, String(utf16CodeUnits: chars, count: len) == ch { return code }
        }
        return nil
    }
}
if let why = keyGuard(pid, app) {
    for id in ["K1 keys 1-5 select tools", "K2 [ ] change brush size", "K3 copy-path key", "K4-K9 reassigning shortcuts"] { rec(id, "blocked", "keyboard guard: \(why)") }
} else {
    let toolKeys: [(CGKeyCode, Int)] = [(20, Seg.rect), (21, Seg.text), (23, Seg.move), (19, Seg.ellipse), (18, Seg.pen), (22, Seg.line)]   // キー 3, 4, 5, 2, 1, 6
    var seen: [Int?] = []
    for (code, _) in toolKeys { key(code, []); seen.append(radioSelected()) }
    rec("K1 default keys 1-6 select tools (the toolbar follows)", seen == toolKeys.map { Optional($0.1) } ? "pass" : "fail", "after keys 3,4,5,2,1,6 the selected segment was \(seen) (expect \(toolKeys.map { $0.1 }); the segments are pen, line, ellipse, rect, text, move)")

    if let smallerKey = keyCodeProducing("["), let largerKey = keyCodeProducing("]") {
        let v0 = sliderValue(); key(largerKey, []); let v1 = sliderValue(); key(smallerKey, []); let v2 = sliderValue()
        if let sl = sliders.first { _ = AXUIElementSetAttributeValue(sl, "AXValue" as CFString, 40 as CFNumber) }
        key(largerKey, []); let vMax = sliderValue()
        if let sl = sliders.first { _ = AXUIElementSetAttributeValue(sl, "AXValue" as CFString, 1 as CFNumber) }
        key(smallerKey, []); let vMin = sliderValue()
        if let sl = sliders.first { _ = AXUIElementSetAttributeValue(sl, "AXValue" as CFString, 4 as CFNumber) }
        rec("K2 ] / [ change the brush size by 2 and stop at the ends (the slider follows)",
            (v0 != nil && v1 == v0.map { $0 + 2 } && v2 == v0 && vMax == 40 && vMin == 1) ? "pass" : "fail",
            "keys: [=\(smallerKey) ]=\(largerKey); start \(String(describing: v0)) -> ] \(String(describing: v1)) -> [ \(String(describing: v2)); at 40 ] -> \(String(describing: vMax)); at 1 [ -> \(String(describing: vMin))")
    } else { rec("K2 ] / [ change the brush size", "blocked", "the current keyboard layout has no unmodified '[' / ']' key to press") }

    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("SNV-SENTINEL", forType: .string)
    key(8, [.maskCommand, .maskShift])
    var copied: String? = nil
    _ = wait(4) { let s = NSPasteboard.general.string(forType: .string); if let s, s != "SNV-SENTINEL" { copied = s; return true }; return false }
    rec("K3 Cmd+Shift+C puts the exported PNG path on the clipboard", (copied.map { $0.hasPrefix(outDir) && $0.hasSuffix(".png") && load($0) != nil } ?? false) ? "pass" : "fail", "clipboard=\(copied ?? "unchanged")")

    if openShortcuts() {
        rec("K4 the status menu opens the shortcuts window", scText("keys-toolPen") == "1" && scText("keys-undo") == "⌘Z / ⌃Z" ? "pass" : "fail",
            "window shown; Pen=\(scText("keys-toolPen")) Undo=\(scText("keys-undo")) Showpanel=\(scText("keys-showPanel"))")

        // 割り当て: ペンを P にする
        var changed = false
        if scPress("change-toolPen"), wait(2, { scText("keys-toolPen").contains("キーを押して") }), shortcutsGuard() == nil {
            key(35, [])
            changed = wait(2) { scText("keys-toolPen") == "P" }
        }
        let saved = bundleIdOK ? readDefault("keyBindings") != nil : false
        let msg5 = scElement("shortcuts-message").map { axs($0, "AXValue") } ?? ""
        closeShortcutsAndShowPanel()
        var effect = false, oldDead = false
        if keyGuard(pid, app) == nil, selectTool(Seg.rect) {
            key(35, []); effect = radioSelected() == Seg.pen          // P でペンになる
            _ = selectTool(Seg.rect); key(18, []); oldDead = radioSelected() == Seg.rect   // 1 では、もう変わらない
        }
        rec("K5 a reassigned key works, the old key stops, and the change is saved", (changed && effect && oldDead && (saved || !bundleIdOK)) ? "pass" : "fail",
            "window shows P=\(changed) P selects pen=\(effect) old '1' ignored=\(oldDead) saved=\(saved) message='\(msg5)'")

        // 競合と予約と取り消し
        if openShortcuts() {
            var conflict = false, reserved = false, cancelled = false
            if scPress("change-toolEllipse"), wait(2, { scText("keys-toolEllipse").contains("キーを押して") }), shortcutsGuard() == nil {
                key(20, [])   // 3 は「四角」が使っている
                let m = scElement("shortcuts-message").map { axs($0, "AXValue") } ?? ""
                conflict = m.contains("ツール: 四角") && scText("keys-toolEllipse") == "2"
                rec("K6 a key used by another command is refused with the reason, and nothing changes", conflict ? "pass" : "fail", "message='\(m)' ellipse now=\(scText("keys-toolEllipse"))")
            } else { rec("K6 conflict is refused", "blocked", "could not start recording") }
            if scPress("change-toolEllipse"), wait(2, { scText("keys-toolEllipse").contains("キーを押して") }), shortcutsGuard() == nil {
                key(8, .maskCommand)   // Cmd+C は予約
                let m = scElement("shortcuts-message").map { axs($0, "AXValue") } ?? ""
                reserved = m.contains("割り当てられません") && scText("keys-toolEllipse") == "2"
                rec("K7 a reserved key (Cmd+C) is refused", reserved ? "pass" : "fail", "message='\(m)' ellipse now=\(scText("keys-toolEllipse"))")
            } else { rec("K7 reserved key is refused", "blocked", "could not start recording") }
            if scPress("change-toolEllipse"), wait(2, { scText("keys-toolEllipse").contains("キーを押して") }), shortcutsGuard() == nil {
                key(53, [])   // Esc で取り消し。設定ウィンドウは閉じない
                cancelled = wait(2) { scText("keys-toolEllipse") == "2" } && shortcutsWin() != nil
                rec("K8 Esc cancels recording without closing the window", cancelled ? "pass" : "fail", "ellipse now=\(scText("keys-toolEllipse")) window open=\(shortcutsWin() != nil)")
            } else { rec("K8 Esc cancels recording", "blocked", "could not start recording") }

            // 初期値に戻すときの重なり：ペンは P に変えてある（1 は空いている）。円に 1 を割り当てたあとで、ペンを初期値に戻そうとすると、1 が重なるので拒否する。
            if scPress("change-toolEllipse"), wait(2, { scText("keys-toolEllipse").contains("キーを押して") }), shortcutsGuard() == nil {
                key(18, [])   // 1
                let moved = wait(2) { scText("keys-toolEllipse") == "1" }
                let pressedReset = scPress("reset-toolPen")
                usleep(300_000)
                let m = scElement("shortcuts-message").map { axs($0, "AXValue") } ?? ""
                let refused = m.contains("すでに使っているキー") && m.contains("ツール: 円") && scText("keys-toolPen") == "P" && scText("keys-toolEllipse") == "1"
                rec("K10 'reset' is refused while another command holds the default key, and nothing changes", (moved && pressedReset && refused) ? "pass" : "fail",
                    "ellipse took 1=\(moved) reset pressed=\(pressedReset) message='\(m)' pen now=\(scText("keys-toolPen")) ellipse now=\(scText("keys-toolEllipse"))")
            } else { rec("K10 reset conflict", "blocked", "could not start recording") }

            // すべて初期値に戻す
            let pressed = scPress("shortcuts-reset-all")
            let back = wait(2) { scText("keys-toolPen") == "1" }
            let cleared = bundleIdOK ? wait(2) { readDefault("keyBindings") == nil } : true
            closeShortcutsAndShowPanel()
            var works = false
            if keyGuard(pid, app) == nil, selectTool(Seg.rect) { key(18, []); works = radioSelected() == Seg.pen }
            rec("K9 reset-all restores the defaults and removes the saved overrides", (pressed && back && cleared && works) ? "pass" : "fail", "pressed=\(pressed) window shows 1=\(back) saved value removed=\(cleared) '1' selects pen again=\(works)")
        } else { rec("K6-K9 conflict / reserved / cancel / reset-all", "blocked", "could not reopen the shortcuts window") }
    } else { rec("K4-K9 shortcuts window", "blocked", "the status menu item did not open a focused 'ショートカット' window") }
}

// ---- クリア（A15）：実キー（Cmd+K）と実ボタン。描いたものが消え、背景の画像は残り、Cmd+Z で戻る ----
func clearButtonElement() -> AXUIElement? { collect(app) { axs($0, "AXRole") == "AXButton" && axs($0, "AXTitle") == "クリア" }.first }
if let why = keyGuard(pid, app) {
    for id in ["L1 Cmd+K clears the drawings and keeps the background", "L2 Cmd+Z brings them back; clearing an empty canvas adds no history step", "L3 the クリア button does the same"] { rec(id, "blocked", "keyboard guard: \(why)") }
} else if let cf = canvasFrame() {
    let W = Double(cf.width), H = Double(cf.height)
    canvasWidthPt = W
    let y = H - 18   // 背景（下半分は緑）の上に、黒い線を引く
    _ = selectTool(Seg.pen)
    /// (線が見える, 背景が見える)。背景は、貼り付けた画像の外側（左端）の、背景画像の左上（赤）で見る。
    func state() -> (stroke: Bool, background: Bool)? {
        guard let r = exportImg() else { return nil }
        return (isDark(darkest(r, W * 0.5, y)), isRedish(at(r, W * 0.05, H * 0.3)))
    }
    if drag(line(pt(W * 0.2, y), pt(W * 0.8, y)), pid: pid), let before = state() {
        key(40, .maskCommand)
        let after = state()
        rec("L1 Cmd+K clears the drawings and keeps the background", (before.stroke && before.background && after?.stroke == false && after?.background == true) ? "pass" : "fail",
            "before: stroke=\(before.stroke) background=\(before.background); after Cmd+K: stroke=\(String(describing: after?.stroke)) background=\(String(describing: after?.background))")

        key(40, .maskCommand)   // もう一度。消すものが無いので、何も起きず、履歴にも積まない
        key(6, .maskCommand)    // 取り消しは、クリアの前（線がある状態）へ戻る。履歴が 1 段余計に積まれていれば、まだ線は無い
        let undone = state()
        rec("L2 Cmd+Z brings them back; clearing an empty canvas adds no history step", (undone?.stroke == true && undone?.background == true) ? "pass" : "fail",
            "after Cmd+K, Cmd+K, Cmd+Z: stroke=\(String(describing: undone?.stroke)) background=\(String(describing: undone?.background))")

        if let button = clearButtonElement(), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            usleep(300_000)
            let cleared = state()
            key(6, .maskCommand)
            let restored = state()
            rec("L3 the クリア button does the same", (cleared?.stroke == false && cleared?.background == true && restored?.stroke == true) ? "pass" : "fail",
                "after pressing: stroke=\(String(describing: cleared?.stroke)) background=\(String(describing: cleared?.background)); after Cmd+Z: stroke=\(String(describing: restored?.stroke))")
        } else { rec("L3 the クリア button does the same", "fail", "no AXButton titled クリア was found, or AXPress failed\n" + dumpTree(app)) }
    } else { rec("L1-L3 clear", "blocked", "pointer guard refused the stroke, or the export failed") }
    canvasWidthPt = 480
} else { rec("L1-L3 clear", "blocked", "canvas frame unavailable") }

// ---- 文字サイズ（A17）：ポップアップで選んだ大きさで文字が確定する（ブラシと連動しない）。入力中に変えると、入力欄が大きくなる ----
func textSizePopup() -> AXUIElement? { collect(app) { axs($0, "AXRole") == "AXPopUpButton" && axs($0, "AXIdentifier") == "text-size" }.first }
/// ポップアップを開いて、`title`（例 "64 pt"）の項目を押す。選ばれたことまで見る。
func chooseTextSize(_ title: String) -> Bool {
    guard let popup = textSizePopup() else { print("   chooseTextSize(\(title)): popup not found"); return false }
    if axs(popup, "AXValue") == title { return true }   // すでに選ばれている項目を AXPress すると、メニューが閉じず、次のクリックが取られた（ハーネス側の事情として避ける。人間の操作で同じことが起きるかは、未観測）
    _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
    var item: AXUIElement? = nil
    _ = wait(3) { item = collect(popup) { axs($0, "AXRole") == "AXMenuItem" && axs($0, "AXTitle") == title }.first; return item != nil }
    guard let item else { print("   chooseTextSize(\(title)): menu item not found after AXPress"); return false }
    guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { print("   chooseTextSize(\(title)): AXPress of the item failed"); return false }
    let selected = wait(2) { textSizePopup().map { axs($0, "AXValue") } == title }
    if !selected { print("   chooseTextSize(\(title)): popup shows '\(textSizePopup().map { axs($0, "AXValue") } ?? "?")'") }
    usleep(500_000)   // メニューが閉じきるのを待つ（閉じる途中のクリックは、取られる）
    return selected
}
/// 暗い画素がある行の高さ（pt）。文字の高さを見る。無ければ 0。
func darkHeight(_ r: NSBitmapImageRep, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
    let s = Double(r.pixelsWide) / canvasWidthPt
    var top = Int.max, bottom = -1
    for y in Int(y0 * s)..<Int(y1 * s) {
        for x in Int(x0 * s)..<Int(x1 * s) where isDark(px(r, x, y)) { top = min(top, y); bottom = max(bottom, y); break }
    }
    return bottom < 0 ? 0 : Double(bottom - top + 1) / s
}
/// 文字ツールで (x, y) に "HHH" を入れて Return で確定し、書き出しの (y0, y1) の範囲に出た文字の高さ（pt）を返す。
func typeAndMeasure(_ x: Double, _ y: Double, rows y0: Double, _ y1: Double) -> Double? {
    guard selectTool(Seg.text) else { print("   typeAndMeasure: selectTool failed"); return nil }
    guard click(pt(x, y)) else { print("   typeAndMeasure: click refused"); return nil }
    guard wait(2, { editorAreas().count == 1 }), let ta = editorAreas().first else { print("   typeAndMeasure: editor did not open (count=\(editorAreas().count))"); return nil }
    _ = AXUIElementSetAttributeValue(ta, "AXValue" as CFString, "HHH" as CFString)
    key(36, [])
    guard wait(2, { editorAreas().isEmpty }), let r = exportImg() else { return nil }
    return darkHeight(r, x - 2, y0, x + 300, y1)
}
let textSizeIds = ["X1 the text-size popup exists and defaults to 18 pt", "X2 the chosen size is the size of the committed text (18 pt vs 64 pt)", "X3 the text size does not follow the brush size", "X4 changing the size while typing resizes the editor"]
if let why = keyGuard(pid, app) {
    for id in textSizeIds { rec(id, "blocked", "keyboard guard: \(why)") }
} else if let popup = textSizePopup(), let cf = canvasFrame() {
    canvasWidthPt = Double(cf.width)
    key(40, .maskCommand)   // 描いたものを消して、空の範囲で文字の高さを測る（背景は暗くない）
    let initial = axs(popup, "AXValue")
    rec(textSizeIds[0], initial == "18 pt" ? "pass" : "fail", "AXValue of the popup at launch = '\(initial)'")

    let h18 = chooseTextSize("18 pt") ? typeAndMeasure(120, 30, rows: 26, 60) : nil
    let h64 = chooseTextSize("64 pt") ? typeAndMeasure(120, 70, rows: 62, 170) : nil
    let ok2 = (h18 ?? 0) >= 9 && (h18 ?? 0) <= 18 && (h64 ?? 0) >= 38 && (h64 ?? 0) <= 56 && (h64 ?? 0) > (h18 ?? 0) * 2.2
    rec(textSizeIds[1], ok2 ? "pass" : "fail", "height of the dark rows of 'HHH': 18 pt -> \(h18.map { String(format: "%.1f", $0) } ?? "n/a") pt (expect 9-18), 64 pt -> \(h64.map { String(format: "%.1f", $0) } ?? "n/a") pt (expect 38-56, > 2.2x)")

    // ブラシを 4 -> 24 にして（] を 10 回）、文字サイズは 18 pt のまま。連動していたなら、12 + 24 * 1.5 = 48 pt になる。
    var brushNote = "no ] keycode"
    if let bracket = keyCodeProducing("]"), chooseTextSize("18 pt"), selectTool(Seg.pen) {
        for _ in 0..<10 { key(bracket, []); usleep(60_000) }
        brushNote = "brush slider = \(sliderValue().map { String(format: "%.0f", $0) } ?? "?")"
        let h = typeAndMeasure(120, 190, rows: 182, 300)
        let ok3 = (sliderValue() ?? 0) >= 20 && abs((h ?? 99) - (h18 ?? -99)) <= 2.5
        rec(textSizeIds[2], ok3 ? "pass" : "fail", "\(brushNote); 'HHH' at 18 pt measured \(h.map { String(format: "%.1f", $0) } ?? "n/a") pt vs \(h18.map { String(format: "%.1f", $0) } ?? "n/a") pt at the default brush (a brush-linked size would be 48 pt, ~34 pt tall)")
        for _ in 0..<10 { key(keyCodeProducing("[") ?? bracket, []); usleep(60_000) }
    } else { rec(textSizeIds[2], "blocked", "could not set the brush with the ] key, or select 18 pt / the pen tool") }

    // 入力中に変える：入力欄（AXTextArea）の高さが、新しい大きさの 1 行分以上になる。
    if selectTool(Seg.text), chooseTextSize("18 pt"), click(pt(300, 40)), wait(2, { editorAreas().count == 1 }), let ta = editorAreas().first {
        _ = AXUIElementSetAttributeValue(ta, "AXValue" as CFString, "H" as CFString)
        let before = axSize(ta)?.height ?? 0
        let changed = chooseTextSize("48 pt")
        var after: CGFloat = 0
        _ = wait(2) { after = editorAreas().first.flatMap { axSize($0) }?.height ?? 0; return after >= 62 }
        rec(textSizeIds[3], (changed && before > 0 && before < 40 && after >= 62) ? "pass" : "fail", "editor height at 18 pt = \(before) pt; after choosing 48 pt while typing = \(after) pt (need >= 62: one 48 pt line is 62.4)")
        key(53, [])   // 取り消す
    } else { rec(textSizeIds[3], "blocked", "could not open the editor or select the sizes") }
    canvasWidthPt = 480
} else { for id in textSizeIds { rec(id, "blocked", "the text-size popup (AXIdentifier text-size) or the canvas frame was not found\n" + dumpTree(app)) } }

// ---- キャンバスの縁（A18）：キャンバスの外へ出す操作で、要素が掴めなくなったり、外へはみ出したりしない ----
// ポインタは、自分のウィンドウの中（キャンバスの右の余白と、上のツールバーの帯）までしか出さない。
let edgeIds = ["B1 moving an item past the canvas edge keeps part of it in the canvas", "B2 an item moved past the edge can be grabbed and moved back", "B3 a shape dragged past the right edge ends at the edge", "B4 an item grabbed by an empty corner of its box and dragged far out can still be grabbed and moved back"]
if let why = keyGuard(pid, app) {
    for id in edgeIds { rec(id, "blocked", "keyboard guard: \(why)") }
} else if let cf = canvasFrame() {
    let W = Double(cf.width)
    canvasWidthPt = W
    key(40, .maskCommand)   // 描いたものを消す

    // B3：四角を、右の縁の外（余白）までドラッグする。右の辺は、キャンバスの縁にある（外の余白では、書き出しに出ない）。
    if selectTool(Seg.rect), drag(line(pt(300, 20), pt(W + 8, 50)), pid: pid), let r = exportImg() {
        let edge = darkest(r, W - 1, 35)
        rec(edgeIds[2], isDark(edge) ? "pass" : "fail", "dark pixel at the right edge (x=\(Int(W) - 1), y=35, between the top and bottom sides): lum=\(String(format: "%.2f", edge.lum)); the pointer ended 8 pt outside the canvas")
    } else { rec(edgeIds[2], "blocked", "tool select / drag guard / export failed") }
    key(40, .maskCommand)

    // B1・B2：キャンバスの上の縁に近い四角を、上へ（ツールバーの帯まで）動かす。
    var rectDrawn = false
    if selectTool(Seg.rect), drag(line(pt(100, 12), pt(180, 42)), pid: pid), let r0 = exportImg() { rectDrawn = countDark(r0, 90, 0, 190, 50) > 200 }
    if rectDrawn, selectTool(Seg.move), drag(line(pt(140, 27), pt(140, -30)), pid: pid), let r1 = exportImg() {
        let kept = countDark(r1, 90, 0, 190, 40)
        rec(edgeIds[0], kept > 200 ? "pass" : "fail", "dark pixels of the moved rectangle left inside the canvas (x 90-190, y 0-40) = \(kept) (need > 200; 0 means it was carried out of the canvas and cannot be seen or grabbed)")
        // 戻す：キャンバスの上の縁（y=3）から下へ。要素が縁に残っていれば、掴めて、100 pt 下がる（左の辺が x=100、y=85〜115）。
        if drag(line(pt(140, 3), pt(140, 103)), pid: pid), let r2 = exportImg() {
            let back = darkest(r2, 100, 100)
            rec(edgeIds[1], isDark(back) ? "pass" : "fail", "after dragging from (140, 3) down 100 pt: dark pixel on the rectangle's left side at (100, 100): lum=\(String(format: "%.2f", back.lum))")
        } else { rec(edgeIds[1], "blocked", "drag guard / export failed") }
    } else {
        rec(edgeIds[0], "blocked", "the rectangle was not drawn (drawn=\(rectDrawn)) or the move drag / export failed")
        rec(edgeIds[1], "blocked", "depends on B1")
    }
    key(40, .maskCommand)

    // B4：楕円の外接する範囲の、何も描かれていない左上の角（外側）を掴んで、右下の外（余白・下の帯）まで動かす。
    // 掴んだ点だけをキャンバスの中に残しても、楕円の輪は、角から遠いので、完全に外へ出てしまう。掴める範囲が残っていれば、また掴んで戻せる。
    let H = Double(cf.height)
    if selectTool(Seg.ellipse), drag(line(pt(100, 100), pt(200, 200)), pid: pid), isDark(darkest(exportImg() ?? NSBitmapImageRep(), 100, 150)),
       selectTool(Seg.move), drag(line(pt(103, 103), pt(W + 8, H + 20)), pid: pid) {
        // 掴める範囲（外接する範囲＋4 pt）の、16 pt が、右下の角に残る。そこ（W-10, H-10）を掴んで、左上へ戻す。
        let back = (dx: -300.0, dy: -200.0)
        let moved = drag(line(pt(W - 10, H - 10), pt(W - 10 + back.dx, H - 10 + back.dy)), pid: pid)
        let shift = (x: (W - 110) + back.dx, y: (H - 110) + back.dy)   // 1 回目：掴める範囲が、右下に 16 pt 残る位置まで。2 回目：戻した量
        if moved, let r = exportImg() {
            let ring = darkest(r, 100 + shift.x, 150 + shift.y)   // 楕円の左端（元は (100, 150)）
            rec(edgeIds[3], isDark(ring) ? "pass" : "fail", "after dragging from the empty top-left corner (103,103) out past the bottom-right and back from (\(Int(W) - 10), \(Int(H) - 10)): dark pixel on the ellipse's left end at (\(Int(100 + shift.x)), \(Int(150 + shift.y))): lum=\(String(format: "%.2f", ring.lum))")
        } else { rec(edgeIds[3], "blocked", "drag guard / export failed on the recovery drag") }
    } else { rec(edgeIds[3], "blocked", "the ellipse was not drawn, or the tool select / drag guard failed") }
    canvasWidthPt = 480
} else { for id in edgeIds { rec(id, "blocked", "canvas frame unavailable") } }

// ---- 直線ツール（A19）：実キー 6 で選び、斜めの直線を引き、動かし、取り消す。大きさのない直線は足さない ----
let lineIds = ["N1 key 6 selects the line tool (the 2nd segment, next to the pen)", "N2 a diagonal line is drawn from the start to the end of the drag", "N3 a click without a drag adds no line (Cmd+Z removes the line before it, Cmd+Shift+Z brings it back)", "N4 the move tool carries the line; Cmd+Z puts it back"]
if let why = keyGuard(pid, app) {
    for id in lineIds { rec(id, "blocked", "keyboard guard: \(why)") }
} else if let cf = canvasFrame() {
    canvasWidthPt = Double(cf.width)
    func darkAt(_ x: Double, _ y: Double) -> Bool? { exportImg().map { isDark(darkest($0, x, y)) } }
    key(40, .maskCommand)   // 描いたものを消す
    key(22, [])             // 6：直線
    let selected = wait(2) { radioSelected() == Seg.line }
    rec(lineIds[0], selected ? "pass" : "fail", "selected tool segment after pressing 6 = \(radioSelected().map(String.init) ?? "none") (expect \(Seg.line): the 2nd segment, next to the pen)")

    // 始点 (120,100)、終点 (300,200)。中点は (210,150)。線から離れた、範囲の隅 (300,100)・(120,200) には、何も無い。
    if selected, drag(line(pt(120, 100), pt(300, 200)), pid: pid) {
        let mid = darkAt(210, 150), cornerA = darkAt(300, 100), cornerB = darkAt(120, 200)
        rec(lineIds[1], (mid == true && cornerA == false && cornerB == false) ? "pass" : "fail", "dark at the midpoint (210,150)=\(String(describing: mid)); at the empty corners (300,100)=\(String(describing: cornerA)), (120,200)=\(String(describing: cornerB))")

        // 対照：ペンのクリックは、点を足す（クリックが届くこと、Cmd+Z で消えることの確認）。届いていなければ、以下の「足されない」は、何も見ていないことになる。
        let penClick = selectTool(Seg.pen) && click(pt(50, 250))
        let dotThere = darkAt(50, 250)
        key(6, .maskCommand)
        let dotGone = darkAt(50, 250)
        let control = penClick && dotThere == true && dotGone == false
        // 大きさのないドラッグ（クリック）。線が足されていれば、Cmd+Z で消えるのは、クリックの分で、本物の線が残る。
        let clicked = selectTool(Seg.line) && click(pt(50, 250))
        let nothingDrawn = darkAt(50, 250)
        key(6, .maskCommand)
        let afterUndo = darkAt(210, 150)
        key(6, [.maskCommand, .maskShift])
        let afterRedo = darkAt(210, 150)
        rec(lineIds[2], (control && clicked && nothingDrawn == false && afterUndo == false && afterRedo == true) ? "pass" : "fail", "control (pen click): dot there=\(String(describing: dotThere)), gone after Cmd+Z=\(String(describing: dotGone.map { !$0 })); line-tool click delivered=\(clicked), nothing drawn at the click=\(String(describing: nothingDrawn.map { !$0 })); after Cmd+Z the line is gone=\(String(describing: afterUndo.map { !$0 })); after Cmd+Shift+Z it is back=\(String(describing: afterRedo))")

        // 移動：中点を 60 pt 下へ。線は (120,160)〜(300,260) になる。
        if selectTool(Seg.move), drag(line(pt(210, 150), pt(210, 210)), pid: pid) {
            let movedMid = darkAt(210, 210), oldMid = darkAt(210, 150)
            key(6, .maskCommand)
            let backMid = darkAt(210, 150), movedGone = darkAt(210, 210)
            rec(lineIds[3], (movedMid == true && oldMid == false && backMid == true && movedGone == false) ? "pass" : "fail", "after moving down 60: dark at (210,210)=\(String(describing: movedMid)), at the old midpoint (210,150)=\(String(describing: oldMid)); after Cmd+Z: (210,150)=\(String(describing: backMid)), (210,210)=\(String(describing: movedGone))")
        } else { rec(lineIds[3], "blocked", "tool select / drag guard failed") }
    } else {
        rec(lineIds[1], "blocked", "the line tool was not selected or the drag guard refused")
        rec(lineIds[2], "blocked", "depends on N2"); rec(lineIds[3], "blocked", "depends on N2")
    }
    key(40, .maskCommand)
    canvasWidthPt = 480
} else { for id in lineIds { rec(id, "blocked", "canvas frame unavailable") } }

// ---- CLI の render（A20・A21）：実際の実行ファイルで、アプリを起動せずに PNG を書く。常駐中のアプリ（この実行の候補）が動いていても、転送されずに動く ----
/// 実行ファイルを、引数と標準入力つきで実行して、(終了コード, 標準出力, 標準エラー) を返す。
func runCLI(_ args: [String], stdin: String? = nil, exe: String = buildExe) -> (Int32, String, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = inp
    guard (try? p.run()) != nil else { return (-1, "", "could not run") }
    if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
    try? inp.fileHandleForWriting.close()
    let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: o, encoding: .utf8) ?? "", String(data: e, encoding: .utf8) ?? "")
}
let renderIds = ["R1 render, run while the app is running, writes the 960x640 PNG itself (it is not forwarded to the app)", "R2 the rendered PNG has the operations at the given places and colours", "R3 invalid ops exit 1 with the op index and write nothing; a bad --size exits 2", "R4 ops can be read from stdin, and a coordinate outside the canvas is clamped, not an error"]
do {
    let rdir = "\(work)/render"
    try? FileManager.default.createDirectory(atPath: rdir, withIntermediateDirectories: true)
    let opsFile = "\(rdir)/ops.json", outFile = "\(rdir)/out.png", badOut = "\(rdir)/bad.png", stdinOut = "\(rdir)/stdin.png"
    try? """
    {"version":1,"ops":[{"op":"rect","x":100,"y":100,"w":120,"h":60,"color":"#ff0000","size":6},{"op":"line","from":[300,50],"to":[420,150],"color":"#0000ff","size":5},{"op":"text","x":40,"y":240,"text":"ABC","color":"#000000","fontSize":32}]}
    """.write(toFile: opsFile, atomically: true, encoding: .utf8)
    let appsBefore = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count
    let r1 = runCLI(["render", "-", opsFile, "-o", outFile])
    let json1 = (try? JSONSerialization.jsonObject(with: Data(r1.1.utf8))) as? [String: Any]
    let appsAfter = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count
    let wrote = FileManager.default.fileExists(atPath: outFile)
    rec(renderIds[0], (r1.0 == 0 && wrote && json1?["width"] as? Int == 960 && json1?["height"] as? Int == 640 && appsBefore >= 1 && appsBefore == appsAfter) ? "pass" : "fail",
        "exit=\(r1.0) stdout=\(r1.1.trimmingCharacters(in: .whitespacesAndNewlines)) stderr='\(r1.2)' file written by this process=\(wrote) (a forwarded launch would exit 0 without a JSON line or a PNG); running instances with this bundle ID before/after=\(appsBefore)/\(appsAfter) (the app was running: need >= 1; unchanged)")
    if wrote, let rep = load(outFile) {
        canvasWidthPt = 480
        let rectEdge = at(rep, 100, 130), rectInside = at(rep, 160, 130), lineMid = at(rep, 360, 100), corner = at(rep, 460, 300)
        let textDark = countDark(rep, 40, 240, 100, 280)
        let isRed = rectEdge.r > 0.8 && rectEdge.g < 0.4 && rectEdge.b < 0.4
        let isBlue = lineMid.b > 0.8 && lineMid.r < 0.4 && lineMid.g < 0.4
        let white = { (p: Px) in p.r > 0.95 && p.g > 0.95 && p.b > 0.95 }
        rec(renderIds[1], (isRed && isBlue && white(rectInside) && white(corner) && textDark > 100) ? "pass" : "fail",
            "rect edge red=\(isRed) line midpoint blue=\(isBlue) rect interior white=\(white(rectInside)) far corner white=\(white(corner)) dark px of the text 'ABC'=\(textDark) (need>100)")
    } else { rec(renderIds[1], "blocked", "the PNG was not written, or could not be read") }
    let r3a = runCLI(["render", "-", "-", "-o", badOut], stdin: #"{"version":1,"ops":[{"op":"line","from":[10,10],"to":[90,10]},{"op":"nope"}]}"#)
    let errJson = (try? JSONSerialization.jsonObject(with: Data(r3a.2.utf8))) as? [String: Any]
    let errBody = errJson?["error"] as? [String: Any]
    let r3b = runCLI(["render", "--size", "100x100", "-", opsFile, "-o", badOut])
    rec(renderIds[2], (r3a.0 == 1 && errBody?["code"] as? String == "invalid_ops" && errBody?["op"] as? Int == 1 && r3b.0 == 2 && !FileManager.default.fileExists(atPath: badOut)) ? "pass" : "fail",
        "bad op: exit=\(r3a.0) stderr=\(r3a.2.trimmingCharacters(in: .whitespacesAndNewlines)); --size 100x100: exit=\(r3b.0); output file created=\(FileManager.default.fileExists(atPath: badOut))")
    let r4 = runCLI(["render", "-", "-", "-o", stdinOut], stdin: #"{"version":1,"ops":[{"op":"line","from":[10,10],"to":[5000,10]}]}"#)
    let json4 = (try? JSONSerialization.jsonObject(with: Data(r4.1.utf8))) as? [String: Any]
    rec(renderIds[3], (r4.0 == 0 && json4?["clamped"] as? [Int] == [0] && FileManager.default.fileExists(atPath: stdinOut)) ? "pass" : "fail",
        "exit=\(r4.0) stdout=\(r4.1.trimmingCharacters(in: .whitespacesAndNewlines)) stderr='\(r4.2)'")
    // R5：--help と --version は、アプリを起動せずに、使い方と版を出して、終了コード 0（常駐中のアプリが動いていても、増えない）
    let plistVersion = sh(["plutil", "-extract", "CFBundleShortVersionString", "raw", infoPlistPath]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    let appsBefore5 = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count
    let h = runCLI(["--help"]), hr = runCLI(["render", "--help"]), v = runCLI(["--version"]), v2 = runCLI(["version"]), bad = runCLI(["help", "nope"])
    let appsAfter5 = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count
    rec("R5 --help / render --help / --version print and exit 0 without starting the app; an unknown help topic exits 2",
        (h.0 == 0 && h.1.contains("Usage:") && h.1.contains("snote draw") && hr.0 == 0 && hr.1.hasPrefix("Usage: snote render")
         && v.0 == 0 && v.1.trimmingCharacters(in: .whitespacesAndNewlines) == "ShortNote \(plistVersion)" && v2.1 == v.1
         && bad.0 == 2 && appsBefore5 >= 1 && appsBefore5 == appsAfter5) ? "pass" : "fail",
        "--help exit=\(h.0) (\(h.1.count) chars); render --help exit=\(hr.0); --version exit=\(v.0) stdout='\(v.1.trimmingCharacters(in: .whitespacesAndNewlines))' (Info.plist \(plistVersion)); help nope exit=\(bad.0); running instances before/after=\(appsBefore5)/\(appsAfter5)")
}

// ---- エージェントの操作：常駐中のアプリへ（A22〜A24。draw・get・export・clear とソケット）----
func jsonObj(_ s: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(s.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) as? [String: Any] }
func numOf(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
/// `get` の要素の列と、いまのキャンバスの全体。
func agentGet() -> (items: [[String: Any]], editing: Bool, background: [String: Any]?, canvas: (Double, Double))? {
    let r = runCLI(["get"])
    guard r.0 == 0, let j = jsonObj(r.1), let items = j["items"] as? [[String: Any]], let c = j["canvas"] as? [String: Any],
          let w = numOf(c["width"]), let h = numOf(c["height"]) else { return nil }
    return (items, j["editing"] as? Bool ?? false, j["background"] as? [String: Any], (w, h))
}
@discardableResult
func agentDraw(_ ops: String) -> (Int32, [String: Any]?, String) {
    let r = runCLI(["draw", "-"], stdin: #"{"version":1,"ops":["# + ops + "]}")
    return (r.0, jsonObj(r.1), r.2)
}
func agentExportRep() -> (path: String, rep: NSBitmapImageRep)? {
    let r = runCLI(["export"])
    guard r.0 == 0, let p = jsonObj(r.1)?["path"] as? String, let rep = load(p) else { return nil }
    return (p, rep)
}
let isRedPx = { (p: Px) in p.r > 0.8 && p.g < 0.4 && p.b < 0.4 }
let agentIds = [
    "G1 the socket is a socket owned by the user, mode 0600, in a 0700 directory",
    "G2 draw adds a rect to the live canvas (one request, exit 0), and export shows it",
    "G3 get returns the canvas size, the background, and the drawn item in the spec's shape",
    "G4 one draw request is one undo step (Cmd+Z removes all of its items; Cmd+Shift+Z brings them back)",
    "G5 clear removes the drawn items and keeps the background; a second clear says false and adds no undo step",
    "G6 export returns the same file while nothing changed, and a new file after a change",
    "G7 draw while a person is typing: the typed text stays, get says editing, export leaves it out, and the text lands above the agent's item",
    "G8 draw while a person drags an item with the real mouse: the drag continues, nothing is lost, and undo goes in the order committed",
    "G9 draw while the panel is hidden shows it again without taking focus from the frontmost app",
    "G10 draw launches the app when it is not running (without taking focus), and a stale socket from a killed app is replaced",
    "G11 a request that cannot reach the app exits 3 (unreachable); an invalid or oversized request exits 1 without touching the canvas",
    "G12 a normal quit (terminate, not SIGTERM) ends the app within 5 s and removes its socket file",
    "G13 draw through a symlink to the executable (how `snote` is installed) launches the app, draws, and get reaches it",
    "G14 the menu-bar menu has the snote command item (install / uninstall / explanation)",
    "G15 launching through the symlink with no arguments becomes the real app (same bundle id, panel shown), not a second broken instance",
]
var G11state: (Int32, Int32, Int?, Int?, Int, [String: Any]?)? = nil
if agentSocketPath.utf8.count > 103 {
    for id in agentIds { rec(id, "blocked", "socket path too long for this harness (\(agentSocketPath.utf8.count) bytes; the app uses a hashed name then)") }
} else {
    // G1
    let sockAttrs = try? FileManager.default.attributesOfItem(atPath: agentSocketPath)
    let dirAttrs = try? FileManager.default.attributesOfItem(atPath: (agentSocketPath as NSString).deletingLastPathComponent)
    let sockMode = (sockAttrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    let dirMode = (dirAttrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    let isSock = (sockAttrs?[.type] as? FileAttributeType) == .typeSocket
    let mine = (sockAttrs?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    rec(agentIds[0], (isSock && mine && sockMode == 0o600 && dirMode == 0o700) ? "pass" : "fail", "path=\(agentSocketPath) isSocket=\(isSock) ownedByMe=\(mine) mode=\(String(sockMode, radix: 8)) directory mode=\(String(dirMode, radix: 8))")

    // G2・G3：clear で、これまでのケースの内容を空にしてから、四角を 1 つ足す
    _ = runCLI(["clear"])
    if let g0 = agentGet() { canvasWidthPt = g0.canvas.0 }
    let baseline = agentExportRep()                  // 背景の画像（これまでのケースで読んだもの）だけの書き出し
    let d1 = agentDraw(##"{"op":"rect","x":100,"y":100,"w":120,"h":60,"color":"#ff00ff","size":6}"##)
    let g3 = agentGet()
    if let g3 { canvasWidthPt = g3.canvas.0 }
    if let ex = agentExportRep(), let base = baseline {
        let edge = at(ex.rep, 100, 130), inside = at(ex.rep, 160, 130)
        let same = { (a: Px, b: Px) in abs(a.r - b.r) < 0.05 && abs(a.g - b.g) < 0.05 && abs(a.b - b.b) < 0.05 }
        let magenta = edge.r > 0.8 && edge.b > 0.8 && edge.g < 0.4
        rec(agentIds[1], (d1.0 == 0 && d1.1?["added"] as? Int == 1 && magenta && !same(edge, at(base.rep, 100, 130)) && same(inside, at(base.rep, 160, 130))) ? "pass" : "fail",
            "draw exit=\(d1.0) added=\(String(describing: d1.1?["added"])) stderr='\(d1.2)'; exported \(ex.path): rect edge magenta=\(magenta) (differs from the export before the draw: \(!same(edge, at(base.rep, 100, 130)))); interior unchanged=\(same(inside, at(base.rep, 160, 130)))")
    } else { rec(agentIds[1], "blocked", "export failed") }
    if let g3 {
        let it = g3.items.first
        let axSize = canvasFrame().map { ($0.width, $0.height) }
        let sizeOK = axSize.map { abs($0.0 - g3.canvas.0) < 1 && abs($0.1 - g3.canvas.1) < 1 } ?? false
        let shapeOK = g3.items.count == 1 && it?["op"] as? String == "rect" && it?["index"] as? Int == 0 && numOf(it?["x"]) == 100 && numOf(it?["y"]) == 100
            && numOf(it?["w"]) == 120 && numOf(it?["h"]) == 60 && it?["color"] as? String == "#FF00FF" && numOf(it?["size"]) == 6
        let bgOK = g3.background.map { (numOf($0["w"]) ?? 0) > 0 && (numOf($0["h"]) ?? 0) > 0 } ?? false
        rec(agentIds[2], (sizeOK && shapeOK && bgOK && !g3.editing) ? "pass" : "fail",
            "canvas=\(g3.canvas) (AX canvas \(String(describing: axSize))) item=\(String(describing: it)) background=\(String(describing: g3.background)) editing=\(g3.editing)")
    } else { rec(agentIds[2], "blocked", "get failed") }

    // G4：1 回の要求は取り消し 1 段（実キー）
    if let why = keyGuard(pid, app) {
        for i in [3] { rec(agentIds[i], "blocked", "keyboard guard: \(why)") }
    } else {
        agentDraw(##"{"op":"line","from":[300,50],"to":[420,150],"color":"#0000ff","size":5},{"op":"text","x":300,"y":220,"text":"AB","fontSize":32}"##)
        let three = agentGet()?.items.count
        key(6, .maskCommand)
        let afterUndo = agentGet()?.items.count
        key(6, [.maskCommand, .maskShift])
        let afterRedo = agentGet()?.items.count
        rec(agentIds[3], (three == 3 && afterUndo == 1 && afterRedo == 3) ? "pass" : "fail", "items after the 2-op draw=\(String(describing: three)); after one Cmd+Z=\(String(describing: afterUndo)) (expect 1); after Cmd+Shift+Z=\(String(describing: afterRedo)) (expect 3)")
    }

    // G5：clear
    let c1 = jsonObj(runCLI(["clear"]).1)?["cleared"] as? Bool
    let afterClear = agentGet()
    let c2 = jsonObj(runCLI(["clear"]).1)?["cleared"] as? Bool
    var restored: Int? = nil
    if keyGuard(pid, app) == nil { key(6, .maskCommand); restored = agentGet()?.items.count }
    rec(agentIds[4], (c1 == true && afterClear?.items.isEmpty == true && afterClear?.background != nil && c2 == false && restored == 3) ? "pass" : (restored == nil ? "blocked" : "fail"),
        "first clear=\(String(describing: c1)); items after=\(String(describing: afterClear?.items.count)) background kept=\(afterClear?.background != nil); second clear=\(String(describing: c2)); items after one Cmd+Z=\(String(describing: restored)) (expect 3: the second clear made no undo step)")

    // G6：export の再利用
    let e1 = agentExportRep(), e2 = agentExportRep()
    agentDraw(#"{"op":"rect","x":20,"y":20,"w":30,"h":30}"#)
    let e3 = agentExportRep()
    rec(agentIds[5], (e1 != nil && e1?.path == e2?.path && e3 != nil && e3?.path != e1?.path && e1?.path.hasPrefix("/tmp/shortnote/") == true) ? "pass" : "fail",
        "export#1=\(e1?.path ?? "nil") export#2=\(e2?.path ?? "nil") (same expected) after a draw export#3=\(e3?.path ?? "nil") (different expected)")

    // G7：人が文字を入力している間に draw
    _ = runCLI(["clear"])
    if keyGuard(pid, app) != nil {
        rec(agentIds[6], "blocked", "keyboard guard")
    } else if selectTool(Seg.text), click(pt(20, 230)), let ta = editorAreas().first {
        _ = AXUIElementSetAttributeValue(ta, "AXValue" as CFString, "typing" as CFString)
        let pre = agentGet()?.items.count ?? -1
        let d = agentDraw(##"{"op":"rect","x":250,"y":100,"w":100,"h":60,"color":"#ff0000","size":6}"##)
        let during = agentGet()
        let stillOpen = editorAreas().count == 1, stillTyped = editorAreas().first.map { axs($0, "AXValue") } == "typing"
        let exDuring = agentExportRep()
        let textDuring = exDuring.map { countDark($0.rep, 20, 230, 120, 262) } ?? -1
        let redDuring = exDuring.map { isRedPx(at($0.rep, 250, 130)) } ?? false
        key(36, [])
        let closed = wait(2) { editorAreas().isEmpty }
        let after = agentGet()
        let last = after?.items.last, first = after?.items.first
        rec(agentIds[6], (d.0 == 0 && pre == 0 && during?.editing == true && during?.items.count == 1 && stillOpen && stillTyped && textDuring < 20 && redDuring && closed
                          && after?.editing == false && after?.items.count == 2 && first?["op"] as? String == "rect" && last?["op"] as? String == "text" && last?["text"] as? String == "typing") ? "pass" : "fail",
            "draw exit=\(d.0); while typing: editing=\(String(describing: during?.editing)) items=\(String(describing: during?.items.count)) editorOpen=\(stillOpen) editorValueKept=\(stillTyped); export while typing: text dark px=\(textDuring) (<20 expected) rect red=\(redDuring); after Return: editing=\(String(describing: after?.editing)) items=\(String(describing: after?.items.count)) first=\(String(describing: first?["op"])) last=\(String(describing: last?["op"])) text=\(String(describing: last?["text"]))")
    } else { rec(agentIds[6], "blocked", "text tool select / click guard failed") }

    // G8：人が移動のドラッグをしている間に draw（実機のポインタで、ボタンを押したまま）
    _ = runCLI(["clear"])
    agentDraw(##"{"op":"rect","x":60,"y":60,"w":80,"h":50,"color":"#ff0000","size":4}"##)
    let grab = pt(100, 85)
    if keyGuard(pid, app) != nil {
        rec(agentIds[7], "blocked", "keyboard guard")
    } else if selectTool(Seg.move), hitOwner(grab) == pid, hitOwner(pt(160, 85)) == pid {
        post(.mouseMoved, grab); post(.leftMouseDown, grab)
        for p in line(grab, pt(140, 85), steps: 10).dropFirst() { post(.leftMouseDragged, p) }
        usleep(150_000)
        let held = agentGet()                                            // ボタンを押したまま（確定していない）
        let dd = agentDraw(##"{"op":"rect","x":300,"y":200,"w":60,"h":40,"color":"#0000ff","size":4}"##)
        for p in line(pt(140, 85), pt(160, 85), steps: 10).dropFirst() { post(.leftMouseDragged, p) }
        post(.leftMouseUp, pt(160, 85)); usleep(250_000)
        let done = agentGet()
        key(6, .maskCommand); let undo1 = agentGet()
        key(6, .maskCommand); let undo2 = agentGet()
        let heldX = numOf(held?.items.first?["x"]), movedX = numOf(done?.items.first(where: { $0["op"] as? String == "rect" && $0["color"] as? String == "#FF0000" })?["x"])
        let backX = numOf(undo1?.items.first(where: { $0["color"] as? String == "#FF0000" })?["x"])
        rec(agentIds[7], (held?.editing == true && heldX == 60 && dd.0 == 0 && done?.editing == false && done?.items.count == 2 && movedX.map { abs($0 - 120) <= 2 } == true
                          && undo1?.items.count == 2 && backX == 60 && undo2?.items.count == 1) ? "pass" : "fail",
            "while holding the button: editing=\(String(describing: held?.editing)) committed x of the dragged rect=\(String(describing: heldX)) (60 expected: not committed yet); draw exit=\(dd.0); after mouse-up: items=\(String(describing: done?.items.count)) dragged rect x=\(String(describing: movedX)) (about 120); after Cmd+Z: items=\(String(describing: undo1?.items.count)) x=\(String(describing: backX)) (2 items, x back to 60); after a 2nd Cmd+Z: items=\(String(describing: undo2?.items.count)) (1)")
    } else { rec(agentIds[7], "blocked", "move tool select / pointer guard failed") }

    // G11：不正・大きすぎる要求（アプリに触れない）
    let beforeBad = agentGet()?.items.count
    let bad = runCLI(["draw", "-"], stdin: #"{"version":1,"ops":[{"op":"rect","x":1,"y":1,"w":5,"h":5},{"op":"nope"}]}"#)
    let bigFile = "\(work)/render/big-ops.json"
    let onePen = "{\"op\":\"pen\",\"points\":[" + (0..<10_000).map { _ in "[100.5,200.5]" }.joined(separator: ",") + "]}"
    try? ("{\"version\":1,\"ops\":[" + Array(repeating: onePen, count: 9).joined(separator: ",") + "]}").write(toFile: bigFile, atomically: true, encoding: .utf8)
    let big = runCLI(["draw", bigFile])
    let afterBad = agentGet()?.items.count
    let bigSize = (try? FileManager.default.attributesOfItem(atPath: bigFile)[.size] as? Int) ?? 0
    G11state = (bad.0, big.0, beforeBad, afterBad, bigSize, jsonObj(bad.2)?["error"] as? [String: Any])
}

// ---- 円・四角の塗りつぶし（A27）----
let fillIds = [
    "Y1 render: fill:true paints the inside of a rect and an ellipse; outlines and the box corner outside the ellipse stay blank",
    "Y2 draw with fill:true: get reports fill, and the exported inside differs from before while the outline rect's inside does not",
    "Y3 the ellipse/rect buttons: a plain press only selects the tool; the menu (AXShowMenu) sets filled / outline per tool and the drawn shapes follow",
    "Y4 pressing and holding the ellipse button with the real mouse opens the menu (a menu window appears); Esc closes it",
]
do {
    canvasWidthPt = 480
    let ydir = "\(work)/render"
    try? FileManager.default.createDirectory(atPath: ydir, withIntermediateDirectories: true)
    // Y1：render（アプリに触れない）
    let yOut = "\(ydir)/fill.png"
    let y1 = runCLI(["render", "-", "-", "-o", yOut], stdin: ##"{"version":1,"ops":[{"op":"rect","x":100,"y":100,"w":120,"h":80,"color":"#ff0000","fill":true},{"op":"ellipse","x":260,"y":100,"w":120,"h":120,"color":"#0000ff","fill":true},{"op":"rect","x":100,"y":220,"w":120,"h":60,"color":"#00aa00"}]}"##)
    if y1.0 == 0, let rep = load(yOut) {
        let redIn = at(rep, 160, 140), blueIn = at(rep, 320, 160), corner = at(rep, 262, 102), outlineIn = at(rep, 160, 250)
        let white = { (p: Px) in p.r > 0.95 && p.g > 0.95 && p.b > 0.95 }
        rec(fillIds[0], (isRedPx(redIn) && blueIn.b > 0.9 && blueIn.r < 0.1 && white(corner) && white(outlineIn)) ? "pass" : "fail",
            "rect inside red=\(isRedPx(redIn)); ellipse inside blue=\(blueIn.b > 0.9 && blueIn.r < 0.1); the box corner outside the ellipse blank=\(white(corner)); outline rect inside blank=\(white(outlineIn)); stderr='\(y1.2)'")
    } else { rec(fillIds[0], "blocked", "render failed: exit=\(y1.0) \(y1.2)") }

    // Y2：draw（常駐中のアプリ）
    _ = runCLI(["clear"])
    if let g0 = agentGet() { canvasWidthPt = g0.canvas.0 }
    let base = agentExportRep()
    agentDraw(##"{"op":"rect","x":100,"y":100,"w":120,"h":80,"color":"#ff00ff","fill":true},{"op":"ellipse","x":260,"y":100,"w":120,"h":80,"color":"#ff00ff"}"##)
    let g2 = agentGet(), after = agentExportRep()
    if let base, let after, let g2 {
        let differs = { (x: Double, y: Double) -> Bool in let a = at(base.rep, x, y), b = at(after.rep, x, y); return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 0.3 }
        let fills = g2.items.map { $0["fill"] as? Bool }
        rec(fillIds[1], (fills == [true, false] && differs(160, 140) && !differs(320, 140)) ? "pass" : "fail",
            "get fill flags=\(fills) (expect [true, false]); filled rect inside changed=\(differs(160, 140)); outline ellipse inside changed=\(differs(320, 140)) (expect false)")
    } else { rec(fillIds[1], "blocked", "get or export failed") }

    // Y3：ツールバー（Accessibility）。メニューは AXShowMenu で開き、項目を AXPress する
    func axRect(_ e: AXUIElement) -> CGRect? {
        guard let pv = ax(e, "AXPosition"), let sv = ax(e, "AXSize") else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
    func fillMenuItem(_ title: String) -> AXUIElement? { collect(app) { axs($0, "AXRole") == "AXMenuItem" && axs($0, "AXTitle") == title }.first }
    func chooseFill(_ seg: Int, _ title: String) -> Bool {
        AXUIElementSetMessagingTimeout(app, 1.0); defer { AXUIElementSetMessagingTimeout(app, 0) }
        guard AXUIElementPerformAction(radios[seg], "AXShowMenu" as CFString) == .success || true else { return false }
        guard wait(3, { fillMenuItem(title) != nil }), let item = fillMenuItem(title) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
    _ = runCLI(["clear"])
    if keyGuard(pid, app) != nil {
        rec(fillIds[2], "blocked", "keyboard guard"); rec(fillIds[3], "blocked", "keyboard guard")
    } else if radios.count == 6, selectTool(Seg.pen) {
        // 普通に押す：選択だけ。塗りは、まだ枠だけ
        var ok = selectTool(Seg.ellipse) && drag(line(pt(60, 60), pt(160, 140)), pid: pid)
        var shots: [NSBitmapImageRep?] = [exportImg()]
        // 円：塗りつぶしを選ぶ（そのツールに切り替わる）。四角は、枠だけのまま
        _ = selectTool(Seg.pen)
        let pickedFill = chooseFill(Seg.ellipse, "塗りつぶし")
        let toolIsEllipse = wait(2) { (ax(radios[Seg.ellipse], "AXValue") as? NSNumber)?.intValue == 1 }
        usleep(400_000)   // メニューが閉じるのを待つ（閉じ切る前の最初のクリックは、メニューを閉じるだけになる）
        ok = ok && drag(line(pt(220, 60), pt(320, 140)), pid: pid)
        shots.append(exportImg())
        // 四角：普通に押して描く（枠だけのまま）
        ok = ok && selectTool(Seg.rect) && drag(line(pt(60, 180), pt(160, 260)), pid: pid)
        shots.append(exportImg())
        // 円を、枠だけへ戻して描く
        _ = selectTool(Seg.pen)
        let pickedOutline = chooseFill(Seg.ellipse, "枠だけ")
        _ = wait(2) { (ax(radios[Seg.ellipse], "AXValue") as? NSNumber)?.intValue == 1 }
        usleep(400_000)
        ok = ok && drag(line(pt(220, 180), pt(320, 260)), pid: pid)
        shots.append(exportImg())
        if let s = shots.last!, ok {
            let g = agentGet()?.items.map { ($0["op"] as? String ?? "?", $0["fill"] as? Bool ?? false) } ?? []
            let expected: [(String, Bool)] = [("ellipse", false), ("ellipse", true), ("rect", false), ("ellipse", false)]
            let same = g.count == 4 && zip(g, expected).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            let centreDark = [(110.0, 100.0), (270.0, 100.0), (110.0, 220.0), (270.0, 220.0)].map { isDark(at(s, $0.0, $0.1)) }
            rec(fillIds[2], (pickedFill && toolIsEllipse && pickedOutline && same && centreDark == [false, true, false, false]) ? "pass" : "fail",
                "menu picks: fill=\(pickedFill) tool switched to ellipse=\(toolIsEllipse) outline=\(pickedOutline); drawn shapes (op, fill)=\(g) (expect ellipse:false, ellipse:true, rect:false, ellipse:false); inside of each shape dark=\(centreDark) (expect false,true,false,false)")
        } else { rec(fillIds[2], "blocked", "a drag guard refused or an export failed") }

        // Y4：実機のマウスで、円のボタンを押し続ける
        _ = selectTool(Seg.pen)
        if let r = axRect(radios[Seg.ellipse]), hitOwner(CGPoint(x: r.midX, y: r.midY)) == pid {
            let c = CGPoint(x: r.midX, y: r.midY)
            func menuWindows() -> Int { infos(true).filter { owner($0) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 100 }.count }
            let before = menuWindows()
            post(.mouseMoved, c); post(.leftMouseDown, c)
            let opened = wait(2.5) { menuWindows() > before }
            let duringHold = menuWindows()                // ボタンを押している間の、メニューのウィンドウの数
            let itemsVisible = wait(2) { fillMenuItem("塗りつぶし") != nil && fillMenuItem("枠だけ") != nil }
            post(.leftMouseUp, c); usleep(300_000)
            let stillOpen = menuWindows() > before        // ボタンを離しても、メニューは開いたまま（項目を選べる）
            key(53, [])                                   // Esc でメニューを閉じる
            let closed = wait(2) { menuWindows() == before }
            rec(fillIds[3], (opened && itemsVisible && stillOpen && closed) ? "pass" : "fail", "menu windows before=\(before), while holding=\(duringHold) (opened=\(opened)), both menu items in AX=\(itemsVisible), still open after the button was released=\(stillOpen), closed by Esc=\(closed)")
            _ = selectTool(Seg.pen)
        } else { rec(fillIds[3], "blocked", "the ellipse button position / pointer guard") }
    } else { rec(fillIds[2], "blocked", "tool select failed"); rec(fillIds[3], "blocked", "tool select failed") }
}

// ---- 画像の拡大縮小（A28）----
do {
    let resizeIds = [
        "H1 move tool: click an image, drag its bottom-right handle with the real pointer: the opposite corner stays, the aspect ratio is kept, and get reports the new size",
        "H2 one Cmd+Z returns the image to its original box (one undo step), and Cmd+Shift+Z resizes it again",
        "H3 the selection frame and handles are not in the exported PNG (the export is byte-identical before and after selecting)",
    ]
    _ = runCLI(["clear"])
    if let g0 = agentGet() { canvasWidthPt = g0.canvas.0 }
    func imageBox() -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let it = agentGet()?.items.first(where: { $0["op"] as? String == "image" }),
              let x = numOf(it["x"]), let y = numOf(it["y"]), let w = numOf(it["w"]), let h = numOf(it["h"]) else { return nil }
        return (x, y, w, h)
    }
    let drawn = agentDraw(##"{"op":"image","path":"\##(work)/red.png","x":100,"y":100,"w":200,"h":100}"##)
    if drawn.0 != 0 || imageBox() == nil {
        for id in resizeIds { rec(id, "blocked", "draw image failed: exit=\(drawn.0) \(drawn.2)") }
    } else if keyGuard(pid, app) != nil {
        for id in resizeIds { rec(id, "blocked", "keyboard guard") }
    } else if radios.count == 6, selectTool(Seg.move) {
        let original = imageBox()!
        let exportBefore = agentExportRep().flatMap { FileManager.default.contents(atPath: $0.path) }
        let selected = click(pt(200, 150))
        let exportSelected = agentExportRep().flatMap { FileManager.default.contents(atPath: $0.path) }
        rec(resizeIds[2], (selected && exportBefore != nil && exportBefore == exportSelected) ? "pass" : (selected ? "fail" : "blocked"),
            "click delivered=\(selected); export bytes before=\(exportBefore?.count ?? -1) after selecting=\(exportSelected?.count ?? -1) identical=\(exportBefore != nil && exportBefore == exportSelected)")
        // 右下の取っ手（300, 200）を、右へ 60 pt
        let dragged = drag(line(pt(300, 200), pt(360, 200)), pid: pid)
        let after = imageBox()
        if dragged, let a = after {
            let ratio = a.w / a.h
            let grew = a.w > original.w + 40
            let anchorKept = abs(a.x - original.x) <= 1 && abs(a.y - original.y) <= 1
            rec(resizeIds[0], (grew && anchorKept && abs(ratio - 2) < 0.05 && abs(a.w - 260) <= 4) ? "pass" : "fail",
                "before=\(original) after=\(a); grew=\(grew) top-left kept=\(anchorKept) aspect=\(ratio) (expect 2.0 ±0.05) width=\(a.w) (expect ≈260)")
            key(6, .maskCommand)
            let undone = imageBox(), count1 = agentGet()?.items.count
            key(6, [.maskCommand, .maskShift])
            let redone = imageBox()
            let same = { (p: (x: Double, y: Double, w: Double, h: Double)?, q: (x: Double, y: Double, w: Double, h: Double)) -> Bool in
                p.map { abs($0.x - q.x) < 0.01 && abs($0.y - q.y) < 0.01 && abs($0.w - q.w) < 0.01 && abs($0.h - q.h) < 0.01 } ?? false }
            rec(resizeIds[1], (same(undone, original) && count1 == 1 && same(redone, a)) ? "pass" : "fail",
                "after Cmd+Z=\(String(describing: undone)) (expect \(original)), items=\(String(describing: count1)); after Cmd+Shift+Z=\(String(describing: redone)) (expect \(a))")
        } else {
            rec(resizeIds[0], "blocked", "drag guard refused or get failed (dragged=\(dragged))"); rec(resizeIds[1], "blocked", "no resize to undo")
        }
        _ = selectTool(Seg.pen)
        _ = runCLI(["clear"])
    } else { for id in resizeIds { rec(id, "blocked", "tool select failed") } }
}

// ---- アイコン（A16）：バンドルの中身と、メニューバーの項目。メニューバーの画素は、他のプロセスのウィンドウなので撮らない（人間の確認）----
let appBundlePath = URL(fileURLWithPath: buildExe).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let iconName = sh(["plutil", "-extract", "CFBundleIconFile", "raw", infoPlistPath]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let icnsPath = "\(appBundlePath)/Contents/Resources/\(iconName).icns"
let menuPngPath = "\(appBundlePath)/Contents/Resources/MenuBarIcon.png"
let icnsKind = sh(["file", "-b", icnsPath]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let menuRep = load(menuPngPath)
rec("I1 the bundle has AppIcon.icns (named in Info.plist) and the menu-bar image", (iconName == "AppIcon" && icnsKind.hasPrefix("Mac OS X icon") && menuRep?.pixelsWide == 72 && menuRep?.pixelsHigh == 72) ? "pass" : "fail",
    "CFBundleIconFile='\(iconName)' file='\(icnsKind.prefix(40))' menu-bar png=\(menuRep.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "missing")")
let statusItem = statusMenuBar().flatMap { ($0 as AXUIElement).self }.flatMap { (ax($0, "AXChildren") as? [AXUIElement])?.first }
let statusName = statusItem.map { "\(axs($0, "AXDescription")) \(axs($0, "AXTitle"))" } ?? "none"
rec("I2 the menu-bar item exists and is named ShortNote", statusName.contains("ShortNote") ? "pass" : "fail", "AXDescription/AXTitle of the status item: '\(statusName)'")

// Esc last
if keyGuard(pid, app) == nil {
    key(53, [])
    rec("C14 Esc hides panel", wait(2) { candWindow(pid) == nil } ? "pass" : "fail", "on-screen panel gone: \(candWindow(pid) == nil)")
}


// ---- 引数なしの起動でもウィンドウが出る（SPEC 3.1「起動したらすぐ描ける」）----
// 常駐インスタンスがあると転送されて終了するので、先に最初の候補を（起動時刻と実行ファイルを照合して）終了する。
// 保存したサイズが次回の起動で使われることを見るため、ここで 1280 × 720 を選んでから再起動する。
if bundleIdOK { _ = pressMenu("1280 × 720"); _ = waitCanvas(isCanvas(640, 360)) }
let firstStart = sh(["ps", "-p", "\(pid)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
if firstStart == startTime { kill(pid, SIGTERM); _ = wait(3) { !proc.isRunning } }
if proc.isRunning {
    rec("C18 launch without arguments shows the panel", "blocked", "the first candidate did not exit; a resident instance would forward the launch")
} else {
    // G10・G11 の前半：落とした（SIGTERM）候補が残した、応答のないソケット。受け口が無いので、get は届かない（終了コード 3）
    let staleBefore = FileManager.default.fileExists(atPath: agentSocketPath)
    let unreachable = runCLI(["get"])
    let unreachableBody = jsonObj(unreachable.2)?["error"] as? [String: Any]
    let p3 = Process(); p3.executableURL = URL(fileURLWithPath: buildExe)
    p3.standardOutput = FileHandle(forWritingAtPath: "/dev/null"); p3.standardError = FileHandle(forWritingAtPath: "/dev/null")
    try p3.run()
    let pid3 = p3.processIdentifier
    let start3 = sh(["ps", "-p", "\(pid3)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = wait(6) { candWindow(pid3) != nil }
    let b3 = candWindow(pid3).map { bounds($0) } ?? .zero
    rec("C18 launch without arguments shows the panel", shown ? "pass" : "fail", "pid \(pid3) on-screen 'ShortNote' window within 6s: \(shown) bounds \(b3)")
    if shown, agentSocketPath.utf8.count <= 103 {
        let g = runCLI(["get"])
        rec("G10a a stale socket left by a killed app is replaced when the next app starts", (staleBefore && unreachable.0 == 3 && unreachableBody?["code"] as? String == "unreachable" && g.0 == 0 && jsonObj(g.1)?["items"] != nil) ? "pass" : "fail",
            "before the launch: socket file exists=\(staleBefore), get exit=\(unreachable.0) error=\(String(describing: unreachableBody?["code"])) (3/unreachable expected); after the launch: get exit=\(g.0)")
    }
    if shown, bundleIdOK {
        let el3 = AXUIElementCreateApplication(pid3)
        var cf3: CGRect? = nil; _ = wait(5) { cf3 = canvasFrame(el3); return cf3 != nil }
        let okSize = cf3.map { abs($0.width - 640) < 1 && abs($0.height - 360) < 1 } ?? false
        rec("S6 the saved canvas size is applied on the next launch", okSize ? "pass" : "fail", "relaunched candidate canvas \(cf3.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unavailable") pt (expect 640x360 = 1280x720 px)")
    }
    // G12：普通の終了（Cmd+Q と同じ、終了の要求）。アプリが終わり（終了処理で固まらない）、ソケットのファイルが消える
    if sh(["ps", "-p", "\(pid3)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines) == start3 {
        let before = FileManager.default.fileExists(atPath: agentSocketPath)
        NSRunningApplication(processIdentifier: pid3)?.terminate()
        let exited = wait(5) { !p3.isRunning }
        let removed = !FileManager.default.fileExists(atPath: agentSocketPath)
        if agentSocketPath.utf8.count <= 103 { rec(agentIds[11], (before && exited && removed) ? "pass" : "fail", "socket file existed before the quit=\(before); app exited within 5 s=\(exited); socket file removed=\(removed)") }
        if p3.isRunning { kill(pid3, SIGTERM); _ = wait(3) { !p3.isRunning } }
    } else if agentSocketPath.utf8.count <= 103 { rec(agentIds[11], "blocked", "the relaunched candidate could not be identified by its start time") }
    // G10：アプリが動いていないとき、draw が起動する（フォーカスを奪わない）
    if agentSocketPath.utf8.count <= 103, let o = prevFront, o.processIdentifier != pid {
        _ = wait(3) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
        let none = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        o.activate(options: [])
        _ = wait(3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == o.processIdentifier }
        let d = agentDraw(##"{"op":"rect","x":20,"y":20,"w":60,"h":40,"color":"#ff0000","size":5}"##)
        let launched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        let lp = launched?.processIdentifier ?? -1
        let lexe = lp > 0 ? sh(["ps", "-p", "\(lp)", "-o", "comm="]).1.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let lstart = lp > 0 ? sh(["ps", "-p", "\(lp)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let shown4 = lp > 0 && wait(5) { candWindow(lp) != nil }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let g = lp > 0 ? agentGet() : nil
        rec(agentIds[9], (none && d.0 == 0 && d.1?["added"] as? Int == 1 && lexe == buildExe && shown4 && front == o.processIdentifier && g?.items.count == 1) ? "pass" : "fail",
            "no instance before=\(none); draw exit=\(d.0) reply=\(String(describing: d.1)) stderr='\(d.2)'; launched pid=\(lp) exe==candidate=\(lexe == buildExe); its panel on screen=\(shown4); frontmost after=\(front.map { String($0) } ?? "nil") (previous app \(o.processIdentifier) expected); get items=\(String(describing: g?.items.count))")
        // G9：この候補は、前面ではない（draw が前面にしなかった）。パネルを閉じて隠してから、もう一度 draw する。パネルは戻り、フォーカスは動かない。
        if lp > 0, shown4, front == o.processIdentifier {
            let bg = AXUIElementCreateApplication(lp)
            let panelEl = (ax(bg, "AXWindows") as? [AXUIElement])?.first(where: { axs($0, "AXTitle") == "ShortNote" })
            let closeButton = panelEl.flatMap { ax($0, "AXCloseButton") }.map { $0 as! AXUIElement }
            var closed = false
            if let closeButton { _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString); closed = wait(3) { candWindow(lp) == nil } }
            if !closed {
                rec(agentIds[8], "blocked", "could not close the background candidate's panel through Accessibility (close button found: \(closeButton != nil))")
            } else {
                let d2 = agentDraw(##"{"op":"rect","x":20,"y":20,"w":30,"h":30}"##)
                let back = wait(3) { candWindow(lp) != nil }
                let front2 = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let active = NSRunningApplication(processIdentifier: lp)?.isActive ?? true
                rec(agentIds[8], (d2.0 == 0 && back && front2 == o.processIdentifier && !active) ? "pass" : "fail",
                    "the candidate (pid \(lp)) was in the background; its panel was closed; draw exit=\(d2.0); panel on screen again=\(back); frontmost after=\(front2.map { String($0) } ?? "nil") (previous app \(o.processIdentifier) expected); candidate active=\(active) (false expected)")
            }
        } else { rec(agentIds[8], "blocked", "no background candidate (the launch case did not pass)") }
        // 後片付け：この実行で起動した候補だけを、起動時刻と実行ファイルを照合して終わらせる
        if lp > 0, sh(["ps", "-p", "\(lp)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines) == lstart, lexe == buildExe {
            kill(lp, SIGTERM); _ = wait(3) { NSRunningApplication(processIdentifier: lp) == nil || NSRunningApplication(processIdentifier: lp)?.isTerminated == true }
        }
    } else { rec(agentIds[9], "blocked", "no other frontmost app recorded, or the socket path is too long") }
    // G13・G14：リンク経由（`snote` と同じ形：実行ファイルへのシンボリックリンク）。アプリが動いていない状態から、draw が起動して届く
    if agentSocketPath.utf8.count <= 103 {
        _ = wait(5) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
        let none13 = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        let link = "\(work)/snote"
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: buildExe)
        let d13 = runCLI(["draw", "-"], stdin: ##"{"version":1,"ops":[{"op":"rect","x":20,"y":20,"w":60,"h":40,"color":"#ff0000"}]}"##, exe: link)
        let app13 = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        let g13 = runCLI(["get"], exe: link)
        let items13 = (jsonObj(g13.1)?["items"] as? [Any])?.count
        rec(agentIds[12], (none13 && d13.0 == 0 && jsonObj(d13.1)?["added"] as? Int == 1 && app13 != nil && g13.0 == 0 && items13 == 1) ? "pass" : "fail",
            "no instance before=\(none13); draw via the symlink exit=\(d13.0) stdout=\(d13.1.trimmingCharacters(in: .whitespacesAndNewlines)) stderr='\(d13.2.prefix(200))'; launched=\(app13 != nil); get via the symlink exit=\(g13.0) items=\(String(describing: items13))")
        if let a = app13, a.bundleURL?.path == appBundlePath {
            let el = AXUIElementCreateApplication(a.processIdentifier)
            var titles: [(String, Bool)] = []
            _ = wait(5) {
                guard let bar = (ax(el, "AXExtrasMenuBar") ?? ax(el, "AXMenuBar")).map({ $0 as! AXUIElement }) else { return false }
                titles = collect(bar) { axs($0, "AXRole") == "AXMenuItem" && axs($0, "AXTitle").hasPrefix("コマンド「snote」") }.map { (axs($0, "AXTitle"), (ax($0, "AXEnabled") as? NSNumber)?.boolValue ?? false) }
                return !titles.isEmpty
            }
            rec(agentIds[13], titles.count == 1 ? "pass" : "fail", "menu items starting with the snote command label: \(titles.map { "'\($0.0)' enabled=\($0.1)" }) (installing is not pressed: it asks for an administrator password)")
            a.terminate(); _ = wait(5) { NSRunningApplication(processIdentifier: a.processIdentifier)?.isTerminated ?? true }
        } else {
            rec(agentIds[13], "blocked", "the relaunched candidate was not found, or is not this build's bundle")
            if let a = app13 { a.terminate(); _ = wait(5) { NSRunningApplication(processIdentifier: a.processIdentifier)?.isTerminated ?? true } }   // 自分が起動した候補は、見つかった限り、終わらせる
        }
        // G15：引数なしで、リンク経由で起動する。リンクを辿って、本物の実行ファイルに置き換わる（バンドル ID が候補のもの。パネルが出る）
        _ = wait(5) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
        let p15 = Process(); p15.executableURL = URL(fileURLWithPath: link)
        p15.standardOutput = FileHandle(forWritingAtPath: "/dev/null"); p15.standardError = FileHandle(forWritingAtPath: "/dev/null")
        if (try? p15.run()) != nil {
            let pid15 = p15.processIdentifier
            let sameId = wait(6) { NSRunningApplication(processIdentifier: pid15)?.bundleIdentifier == bundleId }
            let shown15 = wait(6) { candWindow(pid15) != nil }
            rec(agentIds[14], (sameId && shown15) ? "pass" : "fail", "process \(pid15) started through the symlink: bundle id == candidate's: \(sameId); its 'ShortNote' panel on screen: \(shown15)")
            NSRunningApplication(processIdentifier: pid15)?.terminate()
            if !wait(5, { !p15.isRunning }) { kill(pid15, SIGTERM) }   // 自分が起動した pid だけ
        } else { rec(agentIds[14], "blocked", "could not start the symlink") }
        try? FileManager.default.removeItem(atPath: link)
    }
    if let s = G11state {
        // G11：届かない（終了コード 3、上の G10a の前）と、不正・大きすぎる要求（終了コード 1、キャンバスは変わらない）
        rec(agentIds[10], (unreachable.0 == 3 && s.0 == 1 && s.1 == 1 && s.2 == s.3 && s.2 != nil && s.4 > 1 << 20 && s.5?["code"] as? String == "invalid_ops" && s.5?["op"] as? Int == 1) ? "pass" : "fail",
            "get with no app: exit=\(unreachable.0) (3 expected); invalid op: exit=\(s.0) error=\(String(describing: s.5)); a \(s.4)-byte request: exit=\(s.1) (1 expected); items before/after the two bad requests=\(String(describing: s.2))/\(String(describing: s.3)) (equal expected)")
    } else { rec(agentIds[10], "blocked", "the live cases did not run") }
}

finish()
