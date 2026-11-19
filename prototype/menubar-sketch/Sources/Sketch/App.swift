import AppKit
import SwiftUI

@main
struct SketchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelContent(chrome: .system)
        } label: {
            Image(systemName: "checklist")
            Text("A " + FakeData.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var custom: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        custom = StatusPanelController()

        guard let variant = ProcessInfo.processInfo.environment["SKETCH_OPEN"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openForCapture(variant) }
    }

    private func openForCapture(_ variant: String) {
        let statusWindows = NSApp.windows.filter { $0.className.contains("NSStatusBarWindow") }
        for window in statusWindows {
            print("STATUS \(window.windowNumber) \(Int(window.frame.minX)) \(Int(window.frame.width))")
        }

        if variant == "B" {
            custom?.open()
        } else {
            print("A has no programmatic open: performClick, sendEvent and the button action (nil) all failed on macOS 27")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let statusNumbers = Set(statusWindows.map(\.windowNumber))
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            for window in NSApp.windows where window.isVisible && !statusNumbers.contains(window.windowNumber) {
                let f = window.frame
                print("PANEL \(window.windowNumber) \(window.className) \(Int(f.minX)) \(Int(primaryHeight - f.maxY)) \(Int(f.width)) \(Int(f.height))")
            }
            fflush(stdout)
        }
    }
}
