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

    private var configuredDirs: [String] {
        guard case .server(let server) = pending.target else { return [] }
        return state.targetDirectories(for: server)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()
                .opacity(0.6)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(pending.payload.entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry)
                        if index < pending.payload.entries.count - 1 {
                            Divider()
                                .opacity(0.5)
                                .padding(.leading, 26)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(
                    pending.mode.label,
                    systemImage: pending.mode == .direct ? "doc" : "archivebox"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

                Spacer()

                HStack(spacing: 6) {
                    Text(t("Total"))
                        .foregroundStyle(.secondary)
                    Text(ByteCount.format(pending.payload.totalBytes))
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(pending.target.isLocal ? t("Local folder") : t("Remote folder"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("", text: $targetDir)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(pending.target.isLocal ? t("Local folder") : t("Remote folder"))

                    if configuredDirs.count > 1 {
                        Menu {
                            ForEach(configuredDirs, id: \.self) { dir in
                                Button {
                                    targetDir = dir
                                    error = nil
                                } label: {
                                    if dir == targetDir.trimmed {
                                        Label(dir, systemImage: "checkmark")
                                    } else {
                                        Text(dir)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(t("Choose a folder"))
                    }

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
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Spacer()
                Button(t("Cancel")) {
                    state.pendingThrow = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(t("Throw to {}", pending.target.displayName)) {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            endpoint(
                icon: pending.payload.source.isLocal ? "laptopcomputer" : "server.rack",
                title: pending.payload.source.displayName,
                subtitle: pending.payload.source.isLocal
                    ? pending.payload.sourceDir
                    : "\(pending.payload.source.server?.address ?? ""):\(pending.payload.sourceDir)"
            )

            Image(systemName: "arrow.right")
                .font(.callout)
                .foregroundStyle(.tertiary)

            endpoint(
                icon: pending.target.isLocal ? "laptopcomputer" : "server.rack",
                title: pending.target.displayName,
                subtitle: pending.target.isLocal
                    ? targetDir
                    : pending.target.server?.address ?? ""
            )

            Spacer(minLength: 0)
        }
    }

    private func endpoint(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.green.opacity(0.10))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.green)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(minWidth: 0, alignment: .leading)
    }

    private func entryRow(_ entry: ThrowEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(entry.sizeText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
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
