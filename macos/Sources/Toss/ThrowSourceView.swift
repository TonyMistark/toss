import SwiftUI
import UniformTypeIdentifiers

/// 一台机器配置的文件夹列表：折叠时只显示路径，点开才去取该目录的文件列表。
struct FolderBrowserPanel: View {
    @ObservedObject var state: AppState
    let source: ThrowTarget

    @State private var opened: Set<String> = []
    @State private var folders: [String: FolderLoad] = [:]
    @State private var selections: [String: Set<String>] = [:]

    private var directories: [String] {
        state.folders(for: source)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if directories.isEmpty {
                    emptyState
                } else {
                    ForEach(directories, id: \.self) { directory in
                        folderCard(directory)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .onChange(of: source.id) { _ in reset() }
        .onChange(of: directories) { _ in reset() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text(t("No folders configured"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func folderCard(_ directory: String) -> some View {
        let load = folders[directory] ?? FolderLoad()
        let isOpen = opened.contains(directory)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    toggle(directory)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)

                        Image(systemName: isOpen ? "folder.fill" : "folder")
                            .font(.callout)
                            .foregroundStyle(isOpen ? Brand.green : Color.secondary)

                        Text(directory)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 8)

                        if load.loading {
                            ProgressView()
                                .controlSize(.small)
                        } else if isOpen {
                            Text(t("{} items", load.entries?.count ?? 0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text(t("Click to load"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await loadFolder(directory, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(load.loading)
                .help(t("Refresh"))
                .accessibilityLabel(t("Refresh"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isOpen {
                Divider()
                    .opacity(0.5)
                folderContent(directory, load: load)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func folderContent(_ directory: String, load: FolderLoad) -> some View {
        if let error = load.error {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let entries = load.entries {
            if entries.isEmpty {
                Text(t("The folder is empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(directory, entry: entry)

                        if index < entries.count - 1 {
                            Divider()
                                .opacity(0.4)
                                .padding(.leading, 42)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        } else {
            Text(t("Click to load"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func entryRow(_ directory: String, entry: ThrowEntry) -> some View {
        let selected = selections[directory]?.contains(entry.name) ?? false

        return HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
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
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? Brand.green.opacity(0.10) : Color.clear)
        .onTapGesture {
            toggleSelection(directory, name: entry.name)
        }
        .onDrag {
            provider(directory: directory, entry: entry)
        }
        .help(entry.name)
    }

    /// 拖拽数据里带上是哪个机器、哪个目录，以及选中的条目。
    private func provider(directory: String, entry: ThrowEntry) -> NSItemProvider {
        let entries = folders[directory]?.entries ?? []
        let selected = selections[directory] ?? []
        let chosen = selected.contains(entry.name)
            ? entries.filter { selected.contains($0.name) }
            : [entry]

        let payload = ThrowPayload(
            source: source,
            sourceDir: directory,
            entries: chosen
        )

        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.json.identifier)
    }

    private func toggle(_ directory: String) {
        if opened.contains(directory) {
            opened.remove(directory)
            return
        }

        opened.insert(directory)
        if folders[directory]?.entries == nil {
            Task { await loadFolder(directory) }
        }
    }

    private func toggleSelection(_ directory: String, name: String) {
        var selected = selections[directory] ?? []
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
        }
        selections[directory] = selected
    }

    private func reset() {
        opened = []
        folders = [:]
        selections = [:]
    }

    @MainActor
    private func loadFolder(_ directory: String, force: Bool = false) async {
        if !force, folders[directory]?.entries != nil { return }

        var load = folders[directory] ?? FolderLoad()
        load.loading = true
        load.error = nil
        folders[directory] = load

        do {
            let entries = try await state.throwing.browse(source: source, directory: directory)
            guard directories.contains(directory) else { return }
            folders[directory] = FolderLoad(entries: entries, loading: false)

            let valid = Set(entries.map(\.name))
            selections[directory] = (selections[directory] ?? []).intersection(valid)
        } catch {
            guard directories.contains(directory) else { return }
            folders[directory] = FolderLoad(error: error.localizedDescription)
        }
    }
}

/// 单个文件夹的加载状态：没加载过时 `entries` 为 nil。
struct FolderLoad {
    var entries: [ThrowEntry]?
    var loading = false
    var error: String?
}
