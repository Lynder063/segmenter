import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if arch(arm64)
        let arch = "ARM64 (Apple Silicon)"
        #elseif arch(x86_64)
        let arch = "x86_64 (Intel)"
        #else
        let arch = "Unknown Arch"
        #endif

        LoggerService.shared.info("==========================================")
        LoggerService.shared.info("🎬 Segmenter Native macOS Starting...")
        LoggerService.shared.info("Architecture: \(arch)")
        LoggerService.shared.info("==========================================")

        // Set activation policy for standard GUI app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Create native macOS window matching docs/screenshot.png layout
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1340, height: 840),
    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
window.title = "Segmenter (Native macOS)"
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.center()
window.contentView = NSHostingView(rootView: MainWindowView())
window.makeKeyAndOrderFront(nil)

app.run()





