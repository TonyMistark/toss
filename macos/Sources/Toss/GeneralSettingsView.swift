import AppKit
import SwiftUI

/// 设置里的「通用」：配置文件位置与默认收发目录。
struct GeneralSettingsView: View {
    @ObservedObject var state: AppState

    @State private var targetDir = ""
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
