import SwiftUI

/// 松手后的确认页：来源 → 目标、条目与总大小、目标目录、传输方式。
struct ThrowConfirmationView: View {
    @ObservedObject var state: AppState
    let pending: PendingThrow

    @State private var targetDir: String
    @State private var error: String?

    init(state: AppState, pending: PendingThrow) {
        self.state = state
        self.pending = pending
        _targetDir = State(initialValue: pending.targetDir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(pending.payload.entries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(.secondary)
                            Text(entry.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(entry.sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text(t("Total"))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteCount.format(pending.payload.totalBytes))
                    .monospacedDigit()
            }
            .font(.callout)

            Text(pending.mode.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(pending.target.isLocal ? t("Local folder") : t("Remote folder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("", text: $targetDir)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(pending.target.isLocal ? t("Local folder") : t("Remote folder"))
                    if pending.target.isLocal {
                        Button {
                            chooseLocalFolder()
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(t("Choose a folder"))
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(t("Cancel")) {
                    state.pendingThrow = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(t("Throw to {}", pending.target.displayName)) {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            endpoint(
                icon: "server.rack",
                title: pending.payload.source.name,
                subtitle: "\(pending.payload.source.address):\(pending.payload.sourceDir)"
            )

            Image(systemName: "arrow.right")
                .font(.title3)
                .foregroundStyle(Brand.green)

            endpoint(
                icon: pending.target.isLocal ? "laptopcomputer" : "server.rack",
                title: pending.target.displayName,
                subtitle: pending.target.isLocal
                    ? targetDir
                    : pending.target.server?.address ?? ""
            )

            Spacer()
        }
    }

    private func endpoint(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Brand.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    private func chooseLocalFolder() {
        if let url = FileChooser.chooseDirectory(
            title: t("Choose a folder"),
            prompt: t("Choose")
        ) {
            targetDir = url.path
            error = nil
        }
    }

    private func confirm() {
        let trimmed = targetDir.trimmed
        guard !trimmed.isEmpty else {
            error = t("Enter a folder path")
            return
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            error = t("Enter an absolute path, or one starting with ~")
            return
        }

        state.confirmThrow(pending, targetDir: trimmed)
    }
}
