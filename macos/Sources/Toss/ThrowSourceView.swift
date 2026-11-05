import SwiftUI
import UniformTypeIdentifiers

/// 选中服务器 = 源：列出该服务器收发目录里的条目，拖到下方投递口。
struct ThrowSourcePanel: View {
    @ObservedObject var state: AppState
    let server: ServerConfig

    @State private var entries: [ThrowEntry] = []
    @State private var selection = Set<String>()
    @State private var isLoading = false
    @State private var error: String?
    @State private var chosenDir: String?

    private var directories: [String] {
        state.targetDirectories(for: server)
    }

    private var directory: String {
        if let chosenDir, directories.contains(chosenDir) {
            return chosenDir
        }
        return directories.first ?? state.effectiveTargetDir(for: server)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if directories.count > 1 {
                    Menu {
                        ForEach(directories, id: \.self) { dir in
                            Button {
                                chosenDir = dir
                                Task { await load() }
                            } label: {
                                if dir == directory {
                                    Label(dir, systemImage: "checkmark")
                                } else {
                                    Text(dir)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(directory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 320, alignment: .leading)
                    .help(t("Choose a folder"))
                } else {
                    Text(directory)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                if !selection.isEmpty {
                    Text(t("{} selected", selection.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help(t("Refresh"))
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if entries.isEmpty && !isLoading && error == nil {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tertiary)
                    Text(t("The folder is empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        ThrowEntryRow(entry: entry)
                            .tag(entry.name)
                            .onDrag {
                                provider(for: entry)
                            }
                    }
                }
                .listStyle(.inset)
            }

            Text(t("Drag an item onto a target below"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
        .task { await load() }
        .onChange(of: server.name) { _ in
            chosenDir = nil
            Task { await load() }
        }
    }

    private func provider(for entry: ThrowEntry) -> NSItemProvider {
        let chosen = selection.contains(entry.name)
            ? entries.filter { selection.contains($0.name) }
            : [entry]

        let payload = ThrowPayload(
            source: server,
            sourceDir: directory,
            entries: chosen
        )

        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.json.identifier)
    }

    @MainActor
    private func load() async {
        let targetDir = directory
        isLoading = true
        error = nil

        do {
            let loaded = try await state.throwing.browse(server: server, directory: targetDir)
            guard targetDir == directory else { return }
            entries = loaded
            selection = selection.filter { name in loaded.contains { $0.name == name } }
        } catch {
            guard targetDir == directory else { return }
            entries = []
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

private struct ThrowEntryRow: View {
    let entry: ThrowEntry

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.callout)
                .foregroundStyle(entry.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(entry.name)
    }
}
