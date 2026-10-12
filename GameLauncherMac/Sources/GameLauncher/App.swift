import SwiftUI
import AppKit

@main
struct GameLauncherApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var library = Library()
    @StateObject private var pads = ControllerManager()

    init() {
        // Nécessaire quand l'app est lancée via `swift run` (hors bundle .app)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Game Launcher") {
            Group {
                if auth.user == nil { LoginView() } else { GalleryView() }
            }
            .frame(minWidth: 860, minHeight: 580)
            .environmentObject(auth)
            .environmentObject(library)
            .environmentObject(pads)
            .onChange(of: auth.user) { _, u in library.load(for: u) }
            .onAppear {
                ShaderOverlay.shared.library = library
                ShaderOverlay.shared.pads = pads
            }
            .preferredColorScheme(.dark)
        }
        Settings { SettingsView().preferredColorScheme(.dark) }
    }
}
