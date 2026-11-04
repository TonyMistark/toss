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

    init() {
        let loaded = TossConfig.load()
        self.config = loaded
        self.selectedServerName = loaded.servers.first?.name
        self.configExists = FileManager.default.fileExists(atPath: loaded.path.path)
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
