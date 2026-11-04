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

    @EnvironmentObject private var profile: ProfileStore

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
                Button {
                    SettingsWindow.open()
                } label: {
                    ProfileAvatar(
                        image: profile.avatar,
                        initial: profile.initial,
                        size: 24
                    )
                }
                .buttonStyle(.plain)
                .help(profile.hasNickname ? profile.nickname : t("Settings"))
                .accessibilityLabel(t("Settings"))
            }
        }
        .sheet(item: $editorTarget) { target in
            ServerEditorView(state: state, target: target)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if state.servers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(t("No servers yet"))
                        .font(.headline)
                    Text(t("Use the Add button below or + in the toolbar"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $state.selectedServerName) {
                    Section(t("Servers")) {
                        ForEach(state.servers) { server in
                            ServerRow(
                                server: server,
                                targetDir: state.effectiveTargetDir(for: server)
                            )
                            .tag(server.name as String?)
                        }
                    }
                }
                .listStyle(.sidebar)
            }

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
            if let server = state.selectedServer {
                ServerDetailView(state: state, server: server) {
                    editorTarget = .edit(server)
                }
                .id(server.name)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(t("Choose or add a server"))
                        .font(.title3)
                    Text(t("Pick a server on the left to send, pull, and browse files."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600)
    }
}

struct ServerRow: View {
    let server: ServerConfig
    let targetDir: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(server.name)
                .font(.headline)
            Text(server.address)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(targetDir)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
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
