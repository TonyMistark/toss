import AppKit
import Foundation

// MARK: - 投递目标

/// 文件从哪里来、落到哪里：另一台服务器，或者这台 Mac。
enum ThrowTarget: Hashable, Identifiable, Codable {
    case server(ServerConfig)
    case local

    var id: String {
        switch self {
        case .server(let server):
            return "server:\(server.name)"
        case .local:
            return "local"
        }
    }

    var displayName: String {
        switch self {
        case .server(let server):
            return server.name
        case .local:
            return t("This Mac")
        }
    }

    var addressLine: String {
        switch self {
        case .server(let server):
            return server.address
        case .local:
            return LocalDelivery.directory
        }
    }

    var server: ServerConfig? {
        if case .server(let server) = self { return server }
        return nil
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

/// 可投递的去处：排除来源自己，避免「自己拖自己」。
enum ThrowTargets {
    static func destinations(servers: [ServerConfig], source: ThrowTarget) -> [ThrowTarget] {
        let sourceName: String?
        if case .server(let server) = source {
            sourceName = server.name
        } else {
            sourceName = nil
        }

        var result = servers
            .filter { $0.name != sourceName }
            .map { ThrowTarget.server($0) }
        if !source.isLocal {
            result.append(.local)
        }
        return result
    }
}

/// 落到哪个篮筐 → 实际投递目录。只接受机器配置里的文件夹。
enum BasketChoice {
    static func directory(_ candidate: String, among folders: [String]) -> String? {
        let trimmed = candidate.trimmed
        guard !trimmed.isEmpty else { return nil }
        return folders.first { $0.trimmed == trimmed }
    }

    /// 只有一个文件夹时整张卡片都能落；有多个时必须选中某一个篮筐。
    static func directory(for basket: Int?, among folders: [String]) -> String? {
        if folders.count == 1 { return folders.first }
        guard let basket, folders.indices.contains(basket) else { return nil }
        return folders[basket]
    }
}

/// 拖拽落点（相对卡片顶部的 y）→ 第几个篮筐。
enum DockBaskets {
    static func index(
        forY y: CGFloat,
        basketTop: CGFloat,
        rowStride: CGFloat,
        count: Int
    ) -> Int? {
        guard count > 1, rowStride > 0 else { return nil }
        let offset = y - basketTop
        guard offset >= 0 else { return nil }
        return min(max(Int(offset / rowStride), 0), count - 1)
    }
}

/// 投递口横向翻页：一次最多移动一屏可见的数量，不会跳过没露过面的机器。
enum DockPaging {
    static func step(index: Int, visible: Int, total: Int, forward: Bool) -> Int {
        let visible = max(1, visible)
        let maxIndex = max(0, total - visible)
        let current = min(max(0, index), maxIndex)
        return forward
            ? min(current + visible, maxIndex)
            : max(current - visible, 0)
    }
}

// MARK: - 源条目

/// 源服务器收发目录里的一个条目。名称在同一个目录里唯一，直接当 id。
struct ThrowEntry: Identifiable, Codable, Hashable {
    var name: String
    var isDirectory: Bool
    var byteSize: Int64

    var id: String { name }

    var sizeText: String { ByteCount.format(byteSize) }
}

/// 一次拖拽带的内容：从哪个机器（服务器或本机）的哪个目录，拖了哪些条目。
struct ThrowPayload: Identifiable, Codable {
    var id = UUID()
    var source: ThrowTarget
    var sourceDir: String
    var entries: [ThrowEntry]

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.byteSize }
    }

    var isSingleFile: Bool {
        entries.count == 1 && !(entries.first?.isDirectory ?? false)
    }

    /// 单文件直传；目录或多选打包 tar.gz。
    var mode: ThrowMode { isSingleFile ? .direct : .archive }
}

enum ThrowMode {
    case direct
    case archive
}

// MARK: - 队列

enum TransferStage: String {
    case queued
    case packing
    case transferring
    case unpacking
    case verifying
    case finished
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .packing, .transferring, .unpacking, .verifying:
            return true
        case .queued, .finished, .failed, .cancelled:
            return false
        }
    }

    var isFinished: Bool {
        switch self {
        case .finished, .failed, .cancelled:
            return true
        case .queued, .packing, .transferring, .unpacking, .verifying:
            return false
        }
    }

    var label: String {
        switch self {
        case .queued: return t("Waiting")
        case .packing: return t("Packing")
        case .transferring: return t("Transferring")
        case .unpacking: return t("Unpacking")
        case .verifying: return t("Verifying")
        case .finished: return t("Done")
        case .failed: return t("Failed")
        case .cancelled: return t("Cancelled")
        }
    }
}

struct TransferJob: Identifiable {
    let id: UUID
    let source: ThrowTarget
    let sourceDir: String
    let target: ThrowTarget
    let targetDir: String
    let entries: [ThrowEntry]
    let createdAt: Date

    var stage: TransferStage = .queued
    var progress: Double?
    var bytesTransferred: Int64 = 0
    var message: String?

    init(
        source: ThrowTarget,
        sourceDir: String,
        target: ThrowTarget,
        targetDir: String,
        entries: [ThrowEntry]
    ) {
        self.id = UUID()
        self.source = source
        self.sourceDir = sourceDir
        self.target = target
        self.targetDir = targetDir
        self.entries = entries
        self.createdAt = Date()
    }

    var mode: ThrowMode {
        entries.count == 1 && !(entries.first?.isDirectory ?? false) ? .direct : .archive
    }

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.byteSize }
    }

    var title: String {
        "\(source.displayName) → \(target.displayName)"
    }

    var entrySummary: String {
        entries.map(\.name).joined(separator: ", ")
    }
}

// MARK: - 本机投递目录

enum LocalDelivery {
    static let preferenceKey = "toss.localDeliveryDir"

    static var defaultDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".toss")
            .path
    }

    /// 用户在设置里改过的目录；没改过就是 ~/.toss。
    static var directory: String {
        let raw = (UserDefaults.standard.string(forKey: preferenceKey) ?? "").trimmed
        let path = raw.isEmpty ? defaultDirectory : raw
        return (path as NSString).expandingTildeInPath
    }

    static func setDirectory(_ value: String) {
        let trimmed = value.trimmed
        if trimmed.isEmpty || trimmed == defaultDirectory {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: preferenceKey)
        }
    }
}

// MARK: - 小工具

struct TossError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ByteCount {
    static func format(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}

/// 同名文件加后缀保留：`report.pdf` → `report-2.pdf` → `report-3.pdf`。
/// 与目标端 shell 里的命名规则保持一致（见 `ThrowCommand.moveScript`）。
enum FileNaming {
    static func uniqueName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }

        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var index = 2
        var candidate = name
        repeat {
            candidate = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            index += 1
        } while existing.contains(candidate)
        return candidate
    }
}
