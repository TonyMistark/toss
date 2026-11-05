import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var config: TossConfig
    @Published var selectedServerName: String?
    @Published private(set) var output: String = ""
    @Published private(set) var busy = false
    @Published private(set) var configExists: Bool

    let transfer = TransferService()
    let throwing = ThrowService()
    let queue = TransferQueue()

    /// 松手后等待确认的投递；由 `ContentView` 的 sheet 展示。
    @Published var pendingThrow: PendingThrow?

    init() {
        let loaded = TossConfig.load()
        self.config = loaded
        self.selectedServerName = loaded.servers.first?.name
        self.configExists = FileManager.default.fileExists(atPath: loaded.path.path)

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: LocalDelivery.directory),
            withIntermediateDirectories: true
        )
    }

    var servers: [ServerConfig] { config.servers }

    var selectedServer: ServerConfig? {
        guard let name = selectedServerName else { return nil }
        return config.servers.first { $0.name == name }
    }

    var configPath: URL { config.path }

    func effectiveTargetDir(for server: ServerConfig) -> String {
        config.effectiveTargetDir(for: server)
    }

    var localDeliveryDir: String { LocalDelivery.directory }

    /// 松手后先记下待确认的投递，不直接开始传输。
    /// 只接受来自当前配置里真实存在的服务器，防止伪造的拖拽数据。
    func beginThrow(payload: ThrowPayload, target: ThrowTarget) {
        guard !payload.entries.isEmpty,
              let known = servers.first(where: { $0.name == payload.source.name }),
              known == payload.source
        else { return }

        let directory: String
        switch target {
        case .server(let server):
            directory = effectiveTargetDir(for: server)
        case .local:
            directory = LocalDelivery.directory
        }

        pendingThrow = PendingThrow(payload: payload, target: target, targetDir: directory)
    }

    func confirmThrow(_ pending: PendingThrow, targetDir: String) {
        let trimmed = targetDir.trimmed
        guard !trimmed.isEmpty else { return }

        queue.enqueue(TransferJob(
            source: pending.payload.source,
            sourceDir: pending.payload.sourceDir,
            target: pending.target,
            targetDir: trimmed,
            entries: pending.payload.entries
        ))
        pendingThrow = nil
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
        if !config.servers.contains(where: { $0.name == selectedServerName }) {
            selectedServerName = config.servers.first?.name
        }
    }

    func createConfigIfNeeded() {
        do {
            try config.save()
            configExists = true
            output = t("✓ Config file created: {}", config.path.path)
        } catch {
            output = t("✗ Could not create the config: {}", error.localizedDescription)
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
            if selectedServerName == originalName || selectedServerName == nil {
                selectedServerName = server.name
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
            if selectedServerName == name {
                selectedServerName = config.servers.first?.name
            }
        } catch {
            config = previous
            throw error
        }
    }

    func clearOutput() {
        output = ""
    }

    func run(_ operation: @escaping () async throws -> String) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                output = try await operation()
            } catch {
                output = "✗ \(error.localizedDescription)"
            }
            busy = false
        }
    }
}
