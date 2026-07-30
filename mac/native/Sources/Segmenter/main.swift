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
                minSegmentLengthSec: 15.0,
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
    final class AppDelegate: NSObject, NSApplicationDelegate {
        private func setupMainMenu() {
            let mainMenu = NSMenu()

            // App Menu
            let appMenuItem = NSMenuItem()
            mainMenu.addItem(appMenuItem)
            let appMenu = NSMenu()
            appMenuItem.submenu = appMenu
            appMenu.addItem(withTitle: "About Segmenter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            appMenu.addItem(NSMenuItem.separator())
            appMenu.addItem(withTitle: "Quit Segmenter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

            // Edit Menu (Crucial for Cmd+V Paste, Cmd+C Copy, Cmd+A SelectAll in TextFields)
            let editMenuItem = NSMenuItem()
            mainMenu.addItem(editMenuItem)
            let editMenu = NSMenu(title: "Edit")
            editMenuItem.submenu = editMenu
            editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            editMenu.addItem(NSMenuItem.separator())
            editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

            // Window Menu
            let windowMenuItem = NSMenuItem()
            mainMenu.addItem(windowMenuItem)
            let windowMenu = NSMenu(title: "Window")
            windowMenuItem.submenu = windowMenu
            windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

            NSApp.mainMenu = mainMenu
        }

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

            setupMainMenu()
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
    window.collectionBehavior = [.fullScreenPrimary, .managed]
    window.minSize = NSSize(width: 1000, height: 650)
    window.center()
    window.contentView = NSHostingView(rootView: MainWindowView())
    window.makeKeyAndOrderFront(nil)

    app.run()
}

