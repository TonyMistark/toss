import SwiftUI

@main
struct TossApp: App {
    @StateObject private var state = AppState()
    private let services = AppServices()

    var body: some Scene {
        WindowGroup("Toss") {
            RootView(state: state, services: services)
        }
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(t("About Toss")) {
                    AboutPanel.show()
                }
            }
            CommandGroup(after: .saveItem) {
                Button(t("Reload Configuration")) {
                    state.reload()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsShell(state: state, services: services)
                .environmentObject(services.updates)
                .environmentObject(services.installer)
                .environmentObject(services.crashes)
                .environmentObject(services.profile)
        }
    }
}
