import AppKit
import EGAudio
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Lasam sunetul Mac-ului exact cum era.
        EGEngineStop()
    }
}

@main
struct EGPROApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EQModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.enabled ? "slider.vertical.3" : "speaker.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
