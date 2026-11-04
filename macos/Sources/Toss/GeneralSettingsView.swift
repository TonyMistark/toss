import AppKit
import SwiftUI

/// 设置里的「通用」：配置文件位置与默认收发目录。
struct GeneralSettingsView: View {
    @ObservedObject var state: AppState

    @State private var targetDir = ""
    @State private var localDir = ""
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        Form {
            Section(t("Configuration File")) {
                HStack {
                    Text(state.configPath.path)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(t("Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([state.configPath])
                    }
                    .buttonStyle(.borderless)
                }
                if !state.configExists {
                    Text(t("The config file does not exist yet. Saving creates it."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(t("Default Transfer Folder")) {
                TextField("~/.toss", text: $targetDir)
                    .textFieldStyle(.roundedBorder)
                Text(t("Servers without their own folder use this for sending, pulling, and listing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(t("Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            Section(t("Local Delivery Folder")) {
                HStack(spacing: 8) {
                    TextField(LocalDelivery.defaultDirectory, text: $localDir)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        chooseLocalDir()
                    } label: {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(t("Choose a folder"))
                }
                Text(t("Files dropped onto this Mac land here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(t("Save")) { saveLocalDir() }
                }
            }

            if let message {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(messageIsError ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            targetDir = state.config.globalTargetDir
            localDir = state.localDeliveryDir
        }
    }

    private func chooseLocalDir() {
        if let url = FileChooser.chooseDirectory(
            title: t("Choose a folder"),
            prompt: t("Choose")
        ) {
            localDir = url.path
        }
    }

    private func saveLocalDir() {
        do {
            try state.setLocalDeliveryDir(localDir)
            localDir = state.localDeliveryDir
            message = t("Saved.")
            messageIsError = false
        } catch {
            message = t("Could not save: {}", error.localizedDescription)
            messageIsError = true
        }
    }

    private func save() {
        do {
            try state.setGlobalTargetDir(targetDir.trimmed)
            targetDir = state.config.globalTargetDir
            message = t("Saved.")
            messageIsError = false
        } catch {
            message = t("Could not save: {}", error.localizedDescription)
            messageIsError = true
        }
    }
}
