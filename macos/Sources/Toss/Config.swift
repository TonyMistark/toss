import Foundation

struct ServerConfig: Identifiable, Hashable, Codable {
    var name: String
    var host: String
    var user: String = ""
    var port: Int = 22
    var targetDir: String?

    var id: String { name }

    var address: String { user.isEmpty ? host : "\(user)@\(host)" }

    var hasCustomTargetDir: Bool { !(targetDir ?? "").isEmpty }
}

/// ~/.toss/config.json 的读写。
/// 只修改 file_transfer 段，其余顶层配置原样保留。
struct TossConfig {
    var path: URL
    var globalTargetDir: String
    var servers: [ServerConfig]
    private var raw: [String: Any]

    init(
        path: URL = TossConfig.defaultPath,
        globalTargetDir: String = "~/.toss",
        servers: [ServerConfig] = [],
        raw: [String: Any] = [:]
    ) {
        self.path = path
        self.globalTargetDir = globalTargetDir
        self.servers = servers
        self.raw = raw
    }

    static var defaultPath: URL {
        if let home = ProcessInfo.processInfo.environment["TOSS_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
                .appendingPathComponent(".toss/config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".toss/config.json")
    }

    func effectiveTargetDir(for server: ServerConfig) -> String {
        if let dir = server.targetDir, !dir.isEmpty {
            return dir
        }
        return globalTargetDir
    }

    static func load(from url: URL = TossConfig.defaultPath) -> TossConfig {
        var config = TossConfig(path: url)
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return config
        }

        config.raw = root
        guard let ft = root["file_transfer"] as? [String: Any] else {
            return config
        }

        config.globalTargetDir = (ft["target_dir"] as? String) ?? "~/.toss"

        if let dict = ft["servers"] as? [String: Any] {
            var servers: [ServerConfig] = []
            for (name, value) in dict {
                guard let info = value as? [String: Any],
                      let host = info["host"] as? String,
                      !host.isEmpty else { continue }
                servers.append(ServerConfig(
                    name: name,
                    host: host,
                    user: (info["user"] as? String) ?? "",
                    port: (info["port"] as? Int) ?? 22,
                    targetDir: info["target_dir"] as? String
                ))
            }
            servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            config.servers = servers
        }

        return config
    }

    func save() throws {
        var root = raw
        var ft = (root["file_transfer"] as? [String: Any]) ?? [:]
        ft["target_dir"] = globalTargetDir

        var dict: [String: Any] = [:]
        for server in servers {
            var info: [String: Any] = ["host": server.host]
            if !server.user.isEmpty {
                info["user"] = server.user
            }
            if server.port != 22 {
                info["port"] = server.port
            }
            if server.hasCustomTargetDir, let dir = server.targetDir {
                info["target_dir"] = dir
            }
            dict[server.name] = info
        }
        ft["servers"] = dict
        root["file_transfer"] = ft

        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if data.last != 0x0A {
            data.append(0x0A)
        }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: path, options: .atomic)
    }
}
