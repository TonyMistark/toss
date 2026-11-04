import SwiftUI

struct ServerEditorView: View {
    @ObservedObject var state: AppState
    let target: ServerEditorTarget

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var targetDir = ""
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private var editingName: String? {
        if case .edit(let server) = target {
            return server.name
        }
        return nil
    }

    private var isEditing: Bool { editingName != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? t("Edit Server") : t("Add Server"))
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(t("Name"))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    TextField(t("e.g. prod, nas"), text: $name)
                }
                GridRow {
                    Text(t("Host"))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    TextField(t("IP address or hostname"), text: $host)
                }
                GridRow {
                    Text(t("User"))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    TextField(t("Leave empty to use the SSH default user"), text: $user)
                }
                GridRow {
                    Text(t("Port"))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    TextField("22", text: $port)
                }
                GridRow {
                    Text(t("Transfer folder"))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    TextField(
                        t("Leave empty to inherit the global folder: {}", state.config.globalTargetDir),
                        text: $targetDir
                    )
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(t("Leave the folder empty to inherit the global setting. Remote paths may start with ~/."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack(spacing: 12) {
                if isEditing {
                    Button(t("Delete Server"), role: .destructive) {
                        confirmDelete = true
                    }
                }
                Spacer()
                Button(t("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(t("Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500, height: 400)
        .onAppear {
            populate()
        }
        .alert(t("Delete this server?"), isPresented: $confirmDelete) {
            Button(t("Delete"), role: .destructive) {
                deleteServer()
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: {
            Text(t("This removes \"{}\" from the config file. Files on the server are untouched.", name))
        }
    }

    private func populate() {
        guard case .edit(let server) = target else { return }
        name = server.name
        host = server.host
        user = server.user
        port = "\(server.port)"
        targetDir = server.targetDir ?? ""
    }

    private func save() {
        let newName = name.trimmed
        let newHost = host.trimmed
        let newUser = user.trimmed
        let newDir = targetDir.trimmed

        guard !newName.isEmpty else {
            errorMessage = t("Name cannot be empty")
            return
        }
        guard !newHost.isEmpty else {
            errorMessage = t("Host cannot be empty")
            return
        }
        guard let portValue = Int(port.trimmed), (1...65535).contains(portValue) else {
            errorMessage = t("Port must be an integer from 1 to 65535")
            return
        }

        let server = ServerConfig(
            name: newName,
            host: newHost,
            user: newUser,
            port: portValue,
            targetDir: newDir.isEmpty ? nil : newDir
        )

        do {
            try state.upsert(server: server, originalName: editingName)
            dismiss()
        } catch {
            errorMessage = t("Could not save: {}", error.localizedDescription)
        }
    }

    private func deleteServer() {
        guard let editingName else { return }
        do {
            try state.deleteServer(named: editingName)
            dismiss()
        } catch {
            errorMessage = t("Could not delete: {}", error.localizedDescription)
        }
    }
}
