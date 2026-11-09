import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ServerEditorTarget: Identifiable {
    case add
    case edit(ServerConfig)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let server):
            return "edit-\(server.name)"
        }
    }
}

/// 顶部一排机器，下面是被选中那台的文件列表，底部是传输队列。
/// 拖动文件时，其余机器展开文件夹篮筐，并从文件画出一条投篮弧线指向悬停的篮筐。
struct ContentView: View {
    @ObservedObject var state: AppState
    @StateObject private var drag = DragSession()

    @State private var editorTarget: ServerEditorTarget?
    @State private var showLog = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            content

            if !showLog, drag.isDragging || drag.shot != nil {
                ShotArcOverlay(drag: drag)
            }
        }
        .coordinateSpace(name: TossSpace.root)
        // 兜底投递口：投篮投中就把系统拖拽「接住」，避免系统再播一次文件飞回原位的动画。
        .onDrop(of: [UTType.json], delegate: WindowDropDelegate(drag: drag))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    editorTarget = .add
                } label: {
                    Label(t("Add Server"), systemImage: "plus")
                }
                .help(t("Add Server"))

                Button {
                    state.reload()
                } label: {
                    Label(t("Reload Configuration"), systemImage: "arrow.clockwise")
                }
                .help(t("Reload ~/.toss/config.json"))

                Button {
                    showLog.toggle()
                } label: {
                    Label(t("Execution Log"), systemImage: "doc.text.magnifyingglass")
                }
                .help(t("Show all operations in this run"))
            }

            ToolbarItem(placement: .primaryAction) {
                SettingsEntryButton {
                    SettingsWindow.open()
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            ServerEditorView(state: state, target: target)
        }
        .onReceive(drag.$launch) { request in
            // 拉弓松手且射线穿过篮筐：这一次投递真正开始。
            guard let request,
                  let target = ThrowTargets.target(id: request.targetID, servers: state.servers)
            else { return }
            let folders = state.folders(for: target)
            guard request.basket >= 0, request.basket < folders.count else { return }
            state.beginThrow(payload: request.payload, target: target,
                             targetDir: folders[request.basket])
        }
        .onChange(of: state.selectedTarget) { _ in
            showLog = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if showLog {
            ExecutionLogView {
                showLog = false
            }
        } else if let target = state.selectedTarget {
            VStack(spacing: 0) {
                MachineBar(state: state, drag: drag, source: target)
                Divider()

                if !state.configExists {
                    configBanner
                }

                detail(target)

                Divider()
                TransferQueueView(queue: state.queue)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                Text(t("Pick a machine above"))
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detail(_ target: ThrowTarget) -> some View {
        switch target {
        case .server(let server):
            ServerDetailView(state: state, drag: drag, server: server) {
                editorTarget = .edit(server)
            }
            .id(server.name)
        case .local:
            LocalDetailView(state: state, drag: drag)
        }
    }

    private var configBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(t("Configuration file not found"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(t("Create Config Template")) {
                state.createConfigIfNeeded()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }
}

/// 选中本机：只列出它的收件文件夹，点开才加载文件。
struct LocalDetailView: View {
    @ObservedObject var state: AppState
    @ObservedObject var drag: DragSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("This Mac"))
                        .font(.title2.weight(.semibold))
                    Text(t("{} folders", state.folders(for: .local).count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(20)

            Divider()

            FolderBrowserPanel(state: state, drag: drag, source: .local)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

enum FileChooser {
    @MainActor
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = t("Choose files or folders to send")
        panel.message = t("You can pick multiple files or folders; folders are packed as tar.gz automatically.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = t("Add")
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func chooseDirectory(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
