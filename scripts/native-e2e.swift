import AppKit
import ApplicationServices

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
// 同じ bundle ID の常駐があると、起動が転送され（候補が出ない）、保存したサイズも本番のものと混ざる。scripts/e2e.sh は bundle ID を変えたコピーで実行する。
if bundleIdOK, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
    print("blocked: an instance with bundle id \(bundleId) is already running; it would receive the launch and its saved canvas size would be touched.\nUse scripts/e2e.sh (re-signed copy with another bundle id), or quit that instance first.")
    exit(77)
}
func readDefault(_ k: String) -> String? { let r = sh(["defaults", "read", bundleId, k]); return r.0 == 0 ? r.1.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
let origDefaults: [String: String?] = bundleIdOK ? ["canvasWidthPx": readDefault("canvasWidthPx"), "canvasHeightPx": readDefault("canvasHeightPx")] : [:]
if bundleIdOK { sh(["defaults", "write", bundleId, "canvasWidthPx", "-int", "960"]); sh(["defaults", "write", bundleId, "canvasHeightPx", "-int", "640"]) }
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
    if let pf = prevFront, pf.processIdentifier != pid { pf.activate(options: []) }
    if let u = userPB { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
    let psStart = sh(["ps", "-p", "\(pid)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    let psExe = sh(["ps", "-p", "\(pid)", "-o", "comm="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    if psStart == startTime && psExe == exePath { kill(pid, SIGTERM); _ = wait(3) { !proc.isRunning } }
    print("cleanup: terminated pid \(pid) (cleanup only, not a quit test); still running=\(proc.isRunning)")
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
rec("C4 AX controls reachable", (boxes.count == 1 && radios.count == 5 && sliders.count == 1) ? "pass" : "fail",
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
func selectTool(_ i: Int) -> Bool { guard radios.count == 5, AXUIElementPerformAction(radios[i], kAXPressAction as CFString) == .success else { return false }
    return wait(2) { (ax(radios[i], "AXValue") as? NSNumber)?.intValue == 1 } }
if selectTool(1), drag(line(pt(300, 60), pt(440, 140)), pid: pid), let p = export(), let r = load(p) {
    let edge = darkest(r, 300, 100), mid = at(r, 370, 100)
    rec("C8 ellipse tool (drag sets size)", (isDark(edge) && isTeal(mid)) ? "pass" : "fail", "edge lum=\(edge.lum) interior teal=\(isTeal(mid))")
} else { rec("C8 ellipse tool", "blocked", "tool select / drag guard failed") }
var rectPath = ""
if selectTool(2), drag(line(pt(300, 170), pt(440, 270)), pid: pid), let p = export(), let r = load(p) {
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
    if selectTool(3), click(pt(20, 20)) {
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
    if selectTool(3), keyGuard(pid, app) == nil, click(pt(20, 70)) {
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
if !dragsrcOK { rec("M1 move tool", "blocked", "needs the D1 image (drag source did not compile)") } else if selectTool(4), drag(line(pt(200, 200), pt(260, 170)), pid: pid), let r = exportImg() {
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
    rec("Z1 window cannot shrink below the canvas minimum", (cMin.width >= 480 && cMin.height >= 320) ? "pass" : "fail", "after asking for 300x200: canvas \(Int(cMin.width))x\(Int(cMin.height)) (minimum 480x320)")

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
    let p3 = Process(); p3.executableURL = URL(fileURLWithPath: buildExe)
    p3.standardOutput = FileHandle(forWritingAtPath: "/dev/null"); p3.standardError = FileHandle(forWritingAtPath: "/dev/null")
    try p3.run()
    let pid3 = p3.processIdentifier
    let start3 = sh(["ps", "-p", "\(pid3)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = wait(6) { candWindow(pid3) != nil }
    let b3 = candWindow(pid3).map { bounds($0) } ?? .zero
    rec("C18 launch without arguments shows the panel", shown ? "pass" : "fail", "pid \(pid3) on-screen 'ShortNote' window within 6s: \(shown) bounds \(b3)")
    if shown, bundleIdOK {
        let el3 = AXUIElementCreateApplication(pid3)
        var cf3: CGRect? = nil; _ = wait(5) { cf3 = canvasFrame(el3); return cf3 != nil }
        let okSize = cf3.map { abs($0.width - 640) < 1 && abs($0.height - 360) < 1 } ?? false
        rec("S6 the saved canvas size is applied on the next launch", okSize ? "pass" : "fail", "relaunched candidate canvas \(cf3.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unavailable") pt (expect 640x360 = 1280x720 px)")
    }
    if sh(["ps", "-p", "\(pid3)", "-o", "lstart="]).1.trimmingCharacters(in: .whitespacesAndNewlines) == start3 { kill(pid3, SIGTERM); _ = wait(3) { !p3.isRunning } }
}

finish()
