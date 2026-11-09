import SwiftUI

/// 选中一台机器：只列出它配置的几个收发文件夹，点开哪个才加载哪个的文件。
struct ServerDetailView: View {
    @ObservedObject var state: AppState
    @ObservedObject var drag: DragSession
    let server: ServerConfig
    let onEdit: () -> Void

    private var folderCount: Int {
        state.folders(for: .server(server)).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            FolderBrowserPanel(state: state, drag: drag, source: .server(server))
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(server.name)
                    .font(.title2.weight(.semibold))

                Text(server.address)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text(t("{} folders", folderCount))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(t("Edit"), action: onEdit)
        }
        .padding(20)
    }
}
