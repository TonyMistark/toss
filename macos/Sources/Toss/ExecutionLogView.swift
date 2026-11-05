import AppKit
import SwiftUI

/// 执行日志页：浏览、拖拽、SSH 命令、传输阶段和错误，全部按时间顺序列出来。
struct ExecutionLogView: View {
    @ObservedObject private var log = OperationLog.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var autoScroll = true

    private var filtered: [LogEntry] {
        let term = query.trimmed
        guard !term.isEmpty else { return log.entries }
        return log.entries.filter {
            $0.message.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(t("Execution Log"))
                .font(.title3.weight(.semibold))

            Text(t("{} entries", filtered.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)

            TextField(t("Search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                Text(t("No log entries yet"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(t("All operations in this run are shown here."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(filtered) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    if let last = filtered.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: log.entries.count) { _ in
                    guard autoScroll, let last = filtered.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timeText)
                .foregroundStyle(.tertiary)
                .frame(width: 78, alignment: .leading)

            Text(levelLabel(entry.level))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 40, alignment: .leading)

            Text(entry.message)
                .foregroundStyle(entry.level == .error ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(t("Logs are kept in memory for this run."))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Toggle(t("Auto-scroll"), isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.caption)

            Button(t("Copy Log")) {
                copyVisibleLog()
            }
            .disabled(filtered.isEmpty)

            Button(t("Clear")) {
                log.clear()
            }
            .disabled(log.entries.isEmpty)

            Button(t("Done")) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func levelLabel(_ level: LogLevel) -> String {
        switch level {
        case .info: return t("Info")
        case .success: return t("Success")
        case .warning: return t("Warning")
        case .error: return t("Error")
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return Brand.green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func copyVisibleLog() {
        let text = filtered.map(\.line).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
