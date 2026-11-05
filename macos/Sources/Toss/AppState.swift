import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var config: TossConfig
    /// 左侧侧边栏选中项：某台服务器，或本机。
    @Published var selectedTarget: ThrowTarget?
    @Published private(set) var configExists: Bool

    let throwing = ThrowService()
    let queue = TransferQueue()

    init() {
        let loaded = TossConfig.load()
        self.config = loaded
        self.selectedTarget = loaded.servers.first.map { .server($0) } ?? .local
        self.configExists = FileManager.default.fileExists(atPath: loaded.path.path)

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: LocalDelivery.directory),
            withIntermediateDirectories: true
        )
    }

    var servers: [ServerConfig] { config.servers }

    var selectedServer: ServerConfig? { selectedTarget?.server }

    var configPath: URL { config.path }

    func targetDirectories(for server: ServerConfig) -> [String] {
        config.targetDirectories(for: server)
    }

    var localDeliveryDir: String { LocalDelivery.directory }

    /// 这台机器可投递的文件夹：服务器读配置，本机就是本地收件目录。
    func folders(for target: ThrowTarget) -> [String] {
        switch target {
        case .server(let server):
            return targetDirectories(for: server)
        case .local:
            return [localDeliveryDir]
        }
    }

    /// 拖进某个篮筐就投递到那个目录。
    /// 服务器来源必须是配置里真实存在的，目标目录也必须是这台机器配置的文件夹，
    /// 防止伪造的拖拽数据；自己拖给自己直接忽略。
    func beginThrow(payload: ThrowPayload, target: ThrowTarget, targetDir: String) {
        guard !payload.entries.isEmpty, payload.source != target else { return }

        if case .server(let source) = payload.source {
            guard let known = servers.first(where: { $0.name == source.name }),
                  known == source
            else { return }
        }

        guard let directory = BasketChoice.directory(targetDir, among: folders(for: target))
        else { return }

        queue.enqueue(TransferJob(
            source: payload.source,
            sourceDir: payload.sourceDir,
            target: target,
            targetDir: directory,
            entries: payload.entries
        ))
    }

    func setLocalDeliveryDir(_ value: String) throws {
        let trimmed = value.trimmed
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw TossError(t("Enter an absolute path, or one starting with ~"))
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: expanded),
            withIntermediateDirectories: true
        )
        LocalDelivery.setDirectory(trimmed)
    }

    func reload() {
        config = TossConfig.load()
        configExists = FileManager.default.fileExists(atPath: config.path.path)
        if case .server(let selected) = selectedTarget {
            // 重新加载后配置对象是新的实例；选中项换成新实例，列表才保持高亮。
            selectedTarget = config.servers
                .first { $0.name == selected.name }
                .map { .server($0) }
                ?? config.servers.first.map { .server($0) }
                ?? .local
        }
    }

    func createConfigIfNeeded() {
        do {
            try config.save()
            configExists = true
        } catch {
            // 侧边栏提示会在下次刷新时重新评估，这里保持静默。
        }
    }

    func setGlobalTargetDir(_ dir: String) throws {
        let previous = config.globalTargetDir
        config.globalTargetDir = dir
        do {
            try config.save()
            configExists = true
        } catch {
            config.globalTargetDir = previous
            throw error
        }
    }

    func upsert(server: ServerConfig, originalName: String?) throws {
        var servers = config.servers

        if let originalName, let index = servers.firstIndex(where: { $0.name == originalName }) {
            if originalName != server.name,
               servers.contains(where: { $0.name == server.name }) {
                throw TossError(t("A server named {} already exists", server.name))
            }
            servers[index] = server
        } else {
            guard !servers.contains(where: { $0.name == server.name }) else {
                throw TossError(t("A server named {} already exists", server.name))
            }
            servers.append(server)
        }

        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let previous = config
        config.servers = servers
        do {
            try config.save()
            configExists = true
            let selectedName = selectedTarget?.server?.name
            if selectedName == originalName || selectedName == nil {
                selectedTarget = .server(server)
            }
        } catch {
            config = previous
            throw error
        }
    }

    func deleteServer(named name: String) throws {
        let previous = config
        config.servers.removeAll { $0.name == name }
        do {
            try config.save()
            configExists = true
            if case .server(let selected) = selectedTarget, selected.name == name {
                selectedTarget = config.servers.first.map { .server($0) } ?? .local
            }
        } catch {
            config = previous
            throw error
        }
    }
}
