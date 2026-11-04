import SwiftUI

/// 根视图：主界面 + 崩溃面板 + 启动时的一次更新检查。
struct RootView: View {
    @ObservedObject var state: AppState
    let services: AppServices

    @StateObject private var crashPrompt: CrashPrompt

    init(state: AppState, services: AppServices) {
        self.state = state
        self.services = services
        _crashPrompt = StateObject(wrappedValue: CrashPrompt(store: services.crashes))
    }

    var body: some View {
        ContentView(state: state)
            .frame(minWidth: 880, minHeight: 580)
            .crashPrompt(crashPrompt)
            .task { crashPrompt.offerIfNeeded() }
            .task { await services.updates.checkIfDue() }
    }
}
