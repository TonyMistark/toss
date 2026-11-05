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

    private var directory: String {
        state.effectiveTargetDir(for: server)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(directory)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

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
        guard !isLoading else { return }
        isLoading = true
        error = nil

        do {
            let loaded = try await state.throwing.browse(server: server, directory: directory)
            entries = loaded
            selection = selection.filter { name in loaded.contains { $0.name == name } }
        } catch {
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
