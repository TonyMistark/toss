import SwiftUI
import UniformTypeIdentifiers

/// 一台机器配置的文件夹列表：折叠时只显示路径，点开才去取该目录的文件列表。
struct FolderBrowserPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var drag: DragSession
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
        // 正在被拖出去的就是这一行：给它套上蓝框，和机器栏里被瞄准的文件夹呼应。
        let isDragSource = drag.isDragging
            && drag.projectile == entry.name
            && drag.draggingDir == directory

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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDragSource
                      ? Brand.source.opacity(0.12)
                      : (selected ? Brand.green.opacity(0.10) : Color.clear))
        )
        .overlay(
            DragSourceFrame(active: isDragSource)
                .allowsHitTesting(false)
        )
        .onTapGesture {
            toggleSelection(directory, name: entry.name)
        }
        .onDrag {
            let payload = payload(directory: directory, entry: entry)
            drag.begin(name: entry.name, payload: payload)
            return provider(for: payload, directory: directory)
        }
        .help(entry.name)
    }

    /// 拖拽数据里带上是哪个机器、哪个目录，以及选中的条目。
    private func payload(directory: String, entry: ThrowEntry) -> ThrowPayload {
        let entries = folders[directory]?.entries ?? []
        let selected = selections[directory] ?? []
        let chosen = selected.contains(entry.name)
            ? entries.filter { selected.contains($0.name) }
            : [entry]

        return ThrowPayload(
            source: source,
            sourceDir: directory,
            entries: chosen
        )
    }

    private func provider(for payload: ThrowPayload, directory: String) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        OperationLog.info(t("Dragging {} from {}",
                            LogFormat.entries(payload.entries),
                            LogFormat.location(source, directory: directory)))
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

        OperationLog.info(t("Loading {} from {}", directory, source.displayName))

        do {
            let entries = try await state.throwing.browse(source: source, directory: directory)
            guard directories.contains(directory) else { return }
            folders[directory] = FolderLoad(entries: entries, loading: false)
            OperationLog.success(t("Loaded {}: {} items", directory, entries.count))

            let valid = Set(entries.map(\.name))
            selections[directory] = (selections[directory] ?? []).intersection(valid)
        } catch {
            guard directories.contains(directory) else { return }
            folders[directory] = FolderLoad(error: error.localizedDescription)
            OperationLog.error(t("Could not load {}: {}", directory, error.localizedDescription))
        }
    }
}

/// 单个文件夹的加载状态：没加载过时 `entries` 为 nil。
struct FolderLoad {
    var entries: [ThrowEntry]?
    var loading = false
    var error: String?
}

/// 被拖动的源文件行上的蓝色描边框：弹入后轻轻呼吸，和机器栏的目标篮筐保持一致。
private struct DragSourceFrame: View {
    let active: Bool

    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Brand.source.opacity(active ? 1 : 0),
                          lineWidth: active ? 2 : 0)
            .shadow(color: Brand.source.opacity(active ? (breathing ? 0.34 : 0.16) : 0),
                    radius: active ? (breathing ? 7 : 4) : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.74), value: active)
            .onChange(of: active) { next in
                breathing = false
                guard next else { return }
                breathe()
            }
            .onAppear {
                guard active else { return }
                breathe()
            }
    }

    private func breathe() {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}
