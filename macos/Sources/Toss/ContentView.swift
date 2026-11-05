import AppKit
import SwiftUI

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

struct ContentView: View {
    @ObservedObject var state: AppState

    @State private var editorTarget: ServerEditorTarget?

    var body: some View {
        HSplitView {
            sidebar
            detail
        }
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedTarget) {
                Section {
                    Text(t("This Mac"))
                        .lineLimit(1)
                        .tag(ThrowTarget.local)
                }

                Section(t("Servers")) {
                    ForEach(state.servers) { server in
                        Text(server.name)
                            .lineLimit(1)
                            .tag(ThrowTarget.server(server))
                    }
                }
            }
            .listStyle(.sidebar)

            if !state.configExists {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Configuration file not found"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(t("Create Config Template")) {
                        state.createConfigIfNeeded()
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.orange.opacity(0.10))
            }

            Divider()

            HStack {
                Button {
                    editorTarget = .add
                } label: {
                    Label(t("Add Server"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 340)
    }

    private var detail: some View {
        Group {
            if let target = state.selectedTarget {
                VStack(spacing: 0) {
                    switch target {
                    case .server(let server):
                        ServerDetailView(state: state, server: server) {
                            editorTarget = .edit(server)
                        }
                        .id(server.name)
                    case .local:
                        LocalDetailView(state: state)
                    }

                    Divider()
                    ThrowDockView(state: state, source: target)

                    Divider()
                    TransferQueueView(queue: state.queue)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 40))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tertiary)
                    Text(t("Pick a machine on the left"))
                        .font(.title3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600)
        .sheet(item: $state.pendingThrow) { pending in
            ThrowConfirmationView(state: state, pending: pending)
        }
    }
}

/// 选中本机：把 ~/.toss 里的东西拖到服务器上，就是上传。
struct LocalDetailView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("This Mac"))
                        .font(.title2.weight(.semibold))
                    Text(state.localDeliveryDir)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(20)

            Divider()
                .padding(.bottom, 8)

            ThrowSourcePanel(state: state, source: .local)
                .padding(.horizontal, 20)
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
