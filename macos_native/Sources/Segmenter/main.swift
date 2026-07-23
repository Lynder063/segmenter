import AppKit
import SwiftUI

// Check for CLI test mode: --test-rcd <directory>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--test-rcd" {
    let dirPath = CommandLine.arguments[2]
    let dirURL = URL(fileURLWithPath: dirPath)
    print("🧪 CLI Test Mode: Running per-episode RCD scan on \(dirPath)")

    Task {
        do {
            let results = try await RCDEngineService.shared.scanSeason(
                directoryURL: dirURL,
                method: .appleHWAccelerated,
                minSegmentLengthSec: 45.0,
                similarityThreshold: 80.0 / 100.0,
                debugLogger: { line in print("[DEBUG] \(line)") },
                progressHandler: { text, pct in print("[PROGRESS \(pct)%] \(text)") }
            )

            print("\n========== PER-EPISODE RESULTS ==========")
            for (filename, matches) in results.sorted(by: { $0.key < $1.key }) {
                print("\n📺 \(filename):")
                for m in matches {
                    let sM = Int(m.startSec) / 60, sS = Int(m.startSec) % 60
                    let eM = Int(m.endSec) / 60, eS = Int(m.endSec) % 60
                    print("   \(m.type.rawValue.uppercased()): \(String(format: "%02d:%02d", sM, sS)) - \(String(format: "%02d:%02d", eM, eS)) (confidence: \(String(format: "%.1f%%", m.confidence * 100)))")
                }
            }
            print("\n✅ \(results.count) episodes with individually-located segments.")
        } catch {
            print("❌ Error: \(error)")
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    // Normal GUI app mode
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
}


