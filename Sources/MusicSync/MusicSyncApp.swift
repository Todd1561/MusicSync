import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MusicSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var sync = SyncViewModel()
    @StateObject private var organize = OrganizeViewModel()

    var body: some Scene {
        Window("MusicSync", id: "main") {
            ContentView(sync: sync, organize: organize)
        }
        .defaultSize(width: 1140, height: 840)
        .windowResizability(.contentMinSize)
    }
}
