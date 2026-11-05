import Foundation

/// 执行日志的级别，只影响展示颜色与文案。
enum LogLevel: Int, Comparable {
    case info
    case success
    case warning
    case error

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String

    var timeText: String {
        Self.formatter.string(from: date)
    }

    var line: String {
        "[\(timeText)] [\(level.rawValue)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// 只保留最近 N 条，避免长时间运行后无限增长。
struct LogBuffer {
    let limit: Int
    private(set) var entries: [LogEntry] = []

    init(limit: Int = 2000) {
        self.limit = max(1, limit)
    }

    mutating func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// 本次运行的全局操作日志。浏览目录、拖拽投递、每条 SSH 命令、传输阶段与错误都会写到这里。
final class OperationLog: ObservableObject {
    static let shared = OperationLog()

    @Published private(set) var entries: [LogEntry] = []

    private var buffer = LogBuffer()

    private init() {}

    static func info(_ message: String) {
        record(.info, message)
    }

    static func success(_ message: String) {
        record(.success, message)
    }

    static func warning(_ message: String) {
        record(.warning, message)
    }

    static func error(_ message: String) {
        record(.error, message)
    }

    /// 可以从任意线程调用；真正写入 @Published 的数组在主线程完成。
    static func record(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        Task { @MainActor in
            shared.append(entry)
        }
    }

    @MainActor
    func clear() {
        buffer.removeAll()
        entries = []
    }

    @MainActor
    private func append(_ entry: LogEntry) {
        buffer.append(entry)
        entries = buffer.entries
    }
}

/// 日志里统一用「名字 + 地址 + 目录」的写法。
enum LogFormat {
    static func location(_ target: ThrowTarget, directory: String) -> String {
        switch target {
        case .local:
            return "\(t("This Mac")):\(directory)"
        case .server(let server):
            return "\(server.name) (\(server.address)):\(directory)"
        }
    }

    static func entries(_ entries: [ThrowEntry]) -> String {
        entries.map(\.name).joined(separator: ", ")
    }

    static func truncate(_ text: String, _ limit: Int = 240) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count <= limit ? singleLine : String(singleLine.prefix(limit)) + "…"
    }
}
