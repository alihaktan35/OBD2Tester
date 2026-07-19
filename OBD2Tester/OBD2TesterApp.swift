import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct OBD2TesterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("About OBD2Tester", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
