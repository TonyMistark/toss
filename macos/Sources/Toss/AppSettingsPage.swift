import AppKit
import SwiftUI

// MARK: - 设置 › 应用

/// 每个 app 都该有的那一页：**语言 / 版本 / 关于**。
///
/// 它不是「功能中心里的几行，点一下开 sheet」，而是**看得见状态**的：
/// 现在是什么版本、上次检查结果如何、报告存在哪、语言什么时候生效。
/// 设置页里放状态，弹窗只用在「必须打扰」的地方（装更新的那一下）。
///
/// 依赖三个应用级对象，用 `environmentObject` 注入：
/// `UpdateChecker` / `UpdateInstaller` / `CrashStore`。
struct AppSettingsView: View {
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var installer: UpdateInstaller
    @EnvironmentObject var crashes: CrashStore

    /// 界面语言。默认选中项直接取 `L10n.defaultLanguage`——默认值只有一处
    /// 定义，设置页显示的就一定是实际生效的那个。空串 = 用户显式选了
    /// 「跟随系统」；`L10n.userPreference` 读的是同一个 UserDefaults 键。
    @AppStorage("toss.language") private var languageChoice = L10n.defaultLanguage.rawValue

    var body: some View {
        Form {
            Section(t("Language")) {
                Picker(t("Interface language"), selection: $languageChoice) {
                    Text(t("Follow System")).tag("")
                    ForEach(Language.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                Text(t("Takes effect the next time Toss opens — menus and windows are built at launch."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(t("Version")) {
                LabeledContent(t("Toss"), value: updates.currentVersion)
                LabeledContent(t("System"), value: CrashEnvironment.systemDescription)
                HStack {
                    Text(updates.status.summary ?? t("Not checked yet"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    updateAction
                    Button(updates.isChecking ? t("Checking…") : t("Check Now")) {
                        Task { await updates.check(force: true) }
                    }
                    .disabled(updates.isChecking || installer.phase.isWorking)
                }
                // 「检查失败」闪一下就没了，用户永远不知道是网络、限流还是源坏了。
                // 把每个源的原因留在页面上：这一行是排障入口，不是错误弹窗。
                if case .failed = updates.status, !updates.lastFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Check failed:"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(updates.lastFailures) { failure in
                            Text("\(failure.source) · \(failure.reason)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section(t("About")) {
                Button(t("About Toss")) { AboutPanel.show() }
                Button(t("Show Crash Reports")) {
                    NSWorkspace.shared.open(crashes.directory)
                }
                Text(t("Reports are kept on this Mac. Nothing is sent unless you press the button that opens an issue."))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 「有新版」时「立即检查」旁边换成更新的动作：能装就装，
    /// 失败给一条去访达的退路；其他时刻这块是空的。
    @ViewBuilder
    private var updateAction: some View {
        switch (updates.status, installer.phase) {
        case (.available(let version, let sources), .idle):
            if let primary = sources.first {
                Button(t("Update…")) {
                    if let asset = primary.asset {
                        Task {
                            await installer.run(
                                asset: asset, version: version, releaseURL: primary.releaseURL,
                                fallbacks: sources.filter { $0.name != primary.name }.compactMap(\.asset)
                            )
                        }
                    } else {
                        NSWorkspace.shared.open(primary.releaseURL)
                    }
                }
                // 备源入口：默认源下载慢或失败时，换个地方拿同一个 dmg
                if sources.count > 1 {
                    Menu(t("Or download from…")) {
                        ForEach(sources, id: \.name) { source in
                            if source.asset != nil {
                                Button(t("Download from {}", source.name)) {
                                    if let asset = source.asset {
                                        Task {
                                            await installer.run(
                                                asset: asset, version: version, releaseURL: source.releaseURL,
                                                fallbacks: sources.filter { $0.name != source.name }.compactMap(\.asset)
                                            )
                                        }
                                    }
                                }
                            }
                            Button(t("Open {} release page", source.name)) {
                                NSWorkspace.shared.open(source.releaseURL)
                            }
                        }
                    }
                }
            }
        case (_, .downloading(let fraction)):
            Text(t("Downloading {}%", Int(fraction * 100)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        case (_, .installing):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text(t("Installing…")).font(.callout).foregroundStyle(.secondary)
            }
        case (_, .failed(let reason)):
            if installer.downloadedDMG != nil {
                Button(t("Reveal Download")) {
                    installer.revealFallback()
                }
                .help(reason)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(reason)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - 关于面板

/// 系统标准「关于」面板。**三处共用一个实现**：应用菜单、⌘K、设置页。
///
/// 为什么不用 `NSApplication.orderFrontStandardAboutPanel(nil)` 直接了事：
/// 那个只能拿到 Info.plist 里的版权行，既不能写一句「这个 app 是干什么的」，
/// 也不能给仓库链接。自定义 credits 是系统留的口子，用它。
@MainActor
enum AboutPanel {
    static func show() {
        let repository = "https://github.com/TonyMistark/toss"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let credits = NSMutableAttributedString(
            string: t("A simple SCP and SFTP file transfer tool for macOS.\n") + "github.com/TonyMistark/toss",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        credits.addAttribute(
            .link, value: repository,
            range: (credits.string as NSString).range(of: "github.com/TonyMistark/toss")
        )
        NSApp?.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp?.activate(ignoringOtherApps: true)
    }
}

// MARK: - 更新状态的一句话

extension UpdateStatus {
    /// 报告状态给人看的那句话。闲时不说话——没消息就是好消息。
    var summary: String? {
        switch self {
        case .idle: return nil
        case .checking: return t("Checking…")
        case .upToDate(let version): return t("v{} is up to date", version)
        case .available(let version, _): return t("v{} available", version)
        case .failed: return t("Last check failed")
        }
    }
}
