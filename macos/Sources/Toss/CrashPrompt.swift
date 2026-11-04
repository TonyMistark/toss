import Foundation
import SwiftUI

/// 崩完之后的那一问：把 `CrashStore` 里还没看过的报告推到人眼前。
///
/// 视图层不该自己翻账本（「哪一份还没看过」是账本的事），也不该直接
/// `markAllSeen`（那是「处理过了」的语义）。所以中间放这一层薄的：
/// 账本负责事实，这里只负责「现在要不要弹、按了按钮做什么」。
///
/// 用法（根视图上挂一次）：
/// ```swift
/// @StateObject private var prompt = CrashPrompt(store: shared.crashes)
/// // ……
/// content.crashPrompt(prompt)
///     .task { prompt.offerIfNeeded() }
/// ```
@MainActor
final class CrashPrompt: ObservableObject {
    /// 面板是否在眼前。`false` 不等于报告被删掉——文件还在账本目录里。
    @Published var isVisible = false

    private let store: CrashStore

    init(store: CrashStore) {
        self.store = store
    }

    /// 展示中最新的那一份。连着崩的时候先看最新的。
    var report: CrashReport? { store.pending.first }

    /// 同一个目录里还有几份没处理。
    var extraCount: Int {
        let pending = store.pending
        guard let shown = report, pending.contains(where: { $0.id == shown.id }) else {
            return pending.count
        }
        return pending.count - 1
    }

    /// 有没看过的就摊开。启动时问一次——上次死在哪，只有现在能说。
    func offerIfNeeded() {
        guard store.hasPending else { return }
        isVisible = true
    }

    /// 菜单里的「报告问题…」：不带崩溃现场，只有版本、系统与当前文档名。
    ///
    /// 先摊开面板、不直接拉浏览器：让人看一眼要发出去的是什么，再按那个
    /// 按钮。「发不发」这件事，不该由一个菜单项替他决定。
    func reportProblem(documentName: String? = nil, note: String = "") {
        let report = store.recordFeedback(note: note, documentName: documentName)
        store.markSeen(report.id)
        isVisible = true
    }

    func copy(_ report: CrashReport) {
        store.copyToPasteboard(report)
    }

    func reveal(_ report: CrashReport) {
        store.reveal(report)
    }

    /// 打不开浏览器（没网、被策略拦）不算「已经说过」：面板留着，还能复制。
    func openIssue(_ report: CrashReport) {
        _ = store.openIssue(for: report)
    }

    func dismiss() {
        store.markAllSeen()
        isVisible = false
    }
}

// MARK: - 挂到视图上

private struct CrashPromptModifier: ViewModifier {
    @ObservedObject var prompt: CrashPrompt

    func body(content: Content) -> some View {
        content.sheet(isPresented: $prompt.isVisible) {
            CrashPanel(
                report: prompt.report,
                extraCount: prompt.extraCount,
                copy: { prompt.copy($0) },
                reveal: { prompt.reveal($0) },
                openIssue: { prompt.openIssue($0) },
                dismiss: { prompt.dismiss() }
            )
        }
    }
}

extension View {
    /// 把崩溃面板挂在这棵视图树上（一个应用挂一次就够）。
    func crashPrompt(_ prompt: CrashPrompt) -> some View {
        modifier(CrashPromptModifier(prompt: prompt))
    }
}
