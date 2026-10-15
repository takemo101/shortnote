import AppKit

// Test-only drag source: a borderless window that starts a file drag on mouse drag.
// args: <x> <y(top-left)> <w> <h> <file> <resultPath>
let a = CommandLine.arguments
let x = Double(a[1])!, yTop = Double(a[2])!, w = Double(a[3])!, h = Double(a[4])!
let url = URL(fileURLWithPath: a[5]), resultPath = a[6]

final class SrcView: NSView, NSDraggingSource {
    var started = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ r: NSRect) { NSColor.systemOrange.setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }; started = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: 20, y: 10, width: 60, height: 40), contents: NSImage(contentsOf: url) ?? NSImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        try? "\(operation.rawValue)".write(toFile: resultPath, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screenH = NSScreen.screens[0].frame.height
let win = NSWindow(contentRect: NSRect(x: x, y: screenH - yTop - h, width: w, height: h), styleMask: .borderless, backing: .buffered, defer: false)
win.contentView = SrcView(frame: NSRect(x: 0, y: 0, width: w, height: h))
win.level = .floating
win.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { NSApp.terminate(nil) }  // safety net
app.run()
