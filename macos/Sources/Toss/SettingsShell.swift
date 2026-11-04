import AppKit
import SwiftUI

// MARK: - 设置页

enum SettingsTab: String, CaseIterable, Identifiable {
    case profile
    case general
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return t("Profile")
        case .general: return t("General")
        case .app: return t("Application")
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .general: return "gearshape"
        case .app: return "info.circle"
        }
    }
}

struct SettingsShell: View {
    @ObservedObject var state: AppState
    let services: AppServices

    @State private var selection: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 480)
        .environmentObject(services.updates)
        .environmentObject(services.installer)
        .environmentObject(services.crashes)
        .environmentObject(services.profile)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .profile:
            ProfileSettingsView()
        case .general:
            GeneralSettingsView(state: state)
        case .app:
            AppSettingsView()
        }
    }
}

// MARK: - 打开设置窗口

/// 工具栏齿轮 → 系统 Settings 窗口。macOS 13 与 14+ 的选择器不同，两个都试。
@MainActor
enum SettingsWindow {
    static func open() {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
