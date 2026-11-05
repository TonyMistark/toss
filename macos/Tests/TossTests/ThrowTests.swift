import Foundation
import Testing

@testable import Toss

// MARK: - 同名保留

@Suite("投递归名规则")
struct FileNamingTests {
    @Test("没有冲突就原名")
    func keepsName() {
        #expect(FileNaming.uniqueName(for: "report.pdf", existing: []) == "report.pdf")
    }

    @Test("第二次起加 -2、-3，保留扩展名")
    func addsSuffix() {
        #expect(FileNaming.uniqueName(for: "report.pdf", existing: ["report.pdf"]) == "report-2.pdf")
        #expect(
            FileNaming.uniqueName(for: "report.pdf", existing: ["report.pdf", "report-2.pdf"])
                == "report-3.pdf"
        )
        #expect(FileNaming.uniqueName(for: "archive.tar.gz", existing: ["archive.tar.gz"]) == "archive.tar-2.gz")
    }

    @Test("没有扩展名的文件直接加后缀")
    func noExtension() {
        #expect(FileNaming.uniqueName(for: "Makefile", existing: ["Makefile"]) == "Makefile-2")
        #expect(FileNaming.uniqueName(for: ".env", existing: [".env"]) == ".env-2")
    }
}

// MARK: - 默认目录

@Suite("默认投递目录")
struct LocalDeliveryTests {
    @Test("未配置时默认使用 ~/.toss")
    func defaultsToTossFolder() {
        #expect(LocalDelivery.defaultDirectory.hasSuffix("/.toss"))
    }
}

// MARK: - 多目录配置

@Suite("每台机器的多个目录")
struct TargetDirectoriesTests {
    @Test("旧配置的 target_dir 会迁移成目录列表")
    func migratesLegacyTargetDir() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toss-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.json")
        let json: [String: Any] = [
            "file_transfer": [
                "target_dir": "~/.toss",
                "servers": [
                    "nas": ["host": "nas.local", "target_dir": "/data/inbox"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let config = TossConfig.load(from: url)
        let nas = config.servers.first { $0.name == "nas" }
        #expect(nas?.targetDirs == ["/data/inbox"])
        #expect(nas.map { config.targetDirectories(for: $0) } ?? [] == ["/data/inbox"])
    }

    @Test("多个目录能保存并读回，未配置的服务器回落到全局目录")
    func roundTripsMultipleFolders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toss-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.json")
        let server = ServerConfig(
            name: "nas",
            host: "nas.local",
            targetDirs: ["/data/inbox", "/data/archive"]
        )
        let config = TossConfig(
            path: url,
            globalTargetDir: "~/.toss",
            servers: [server]
        )
        try config.save()

        let loaded = TossConfig.load(from: url)
        #expect(loaded.servers.first?.targetDirs == ["/data/inbox", "/data/archive"])

        let plain = ServerConfig(name: "plain", host: "plain.local")
        #expect(loaded.targetDirectories(for: plain) == ["~/.toss"])
        #expect(loaded.effectiveTargetDir(for: plain) == "~/.toss")
    }
}

// MARK: - 投递去向

@Suite("投递去向")
struct ThrowDestinationsTests {
    private let a = ServerConfig(name: "a", host: "a.local")
    private let b = ServerConfig(name: "b", host: "b.local")

    @Test("服务器作为来源时不出现自己，本机作为来源时不出现本机")
    func excludesTheSource() {
        #expect(
            ThrowTargets.destinations(servers: [a, b], source: .server(a))
                == [.server(b), .local]
        )
        #expect(
            ThrowTargets.destinations(servers: [a, b], source: .local)
                == [.server(a), .server(b)]
        )
    }

    @Test("本机作为来源能编码进拖拽数据，往返不丢信息")
    func encodesLocalSource() throws {
        let payload = ThrowPayload(
            source: .local,
            sourceDir: "/Users/ice/.toss",
            entries: [ThrowEntry(name: "report.pdf", isDirectory: false, byteSize: 12)]
        )
        let decoded = try JSONDecoder().decode(
            ThrowPayload.self,
            from: JSONEncoder().encode(payload)
        )
        #expect(decoded.source == .local)
        #expect(decoded.sourceDir == "/Users/ice/.toss")
        #expect(decoded.entries == payload.entries)
    }
}

// MARK: - 投递口翻页

@Suite("投递口翻页")
struct DockPagingTests {
    @Test("每屏 3 张、共 13 张时向右不跨越未显示的机器")
    func forwardStopsAtLastPage() {
        #expect(DockPaging.step(index: 0, visible: 3, total: 13, forward: true) == 3)
        #expect(DockPaging.step(index: 3, visible: 3, total: 13, forward: true) == 6)
        #expect(DockPaging.step(index: 9, visible: 3, total: 13, forward: true) == 10)
        #expect(DockPaging.step(index: 10, visible: 3, total: 13, forward: true) == 10)
    }

    @Test("向左同样只退一屏，到头停在 0")
    func backwardStopsAtStart() {
        #expect(DockPaging.step(index: 10, visible: 3, total: 13, forward: false) == 7)
        #expect(DockPaging.step(index: 4, visible: 3, total: 13, forward: false) == 1)
        #expect(DockPaging.step(index: 1, visible: 3, total: 13, forward: false) == 0)
        #expect(DockPaging.step(index: 0, visible: 3, total: 13, forward: false) == 0)
    }

    @Test("全部能放下时不动；越界索引会被夹回范围")
    func clampsToRange() {
        #expect(DockPaging.step(index: 0, visible: 5, total: 3, forward: true) == 0)
        #expect(DockPaging.step(index: 99, visible: 3, total: 13, forward: true) == 10)
        #expect(DockPaging.step(index: 99, visible: 3, total: 13, forward: false) == 7)
    }
}

// MARK: - 本机目录浏览

@Suite("本机目录浏览")
struct LocalBrowseTests {
    @Test("文件按字节、目录递归求和，隐藏文件也在")
    func listsLocalDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-local-browse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "12345".write(
            to: root.appendingPathComponent("report.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "key".write(
            to: root.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let sub = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "abc".write(
            to: sub.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )

        let entries = try ThrowService().browseLocal(directory: root.path)

        #expect(entries.count == 3)
        #expect(entries.first { $0.name == "report.txt" }?.byteSize == 5)
        #expect(entries.first { $0.name == ".env" }?.byteSize == 3)
        #expect(entries.first { $0.name == "photos" }?.isDirectory == true)
        #expect(entries.first { $0.name == "photos" }?.byteSize == 3)
    }

    @Test("目录不存在时先建出来，列表为空而不是报错")
    func createsMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-local-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try ThrowService().browseLocal(directory: root.path)

        #expect(entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
}

// MARK: - 传输方式

@Suite("投递计划")
struct ThrowPlanTests {
    private let server = ServerConfig(name: "prod", host: "10.0.0.1")

    private func payload(_ entries: [ThrowEntry]) -> ThrowPayload {
        ThrowPayload(source: .server(server), sourceDir: "/srv", entries: entries)
    }

    @Test("单文件直传")
    func singleFileIsDirect() {
        let item = ThrowEntry(name: "report.pdf", isDirectory: false, byteSize: 2_048)
        let value = payload([item])
        #expect(value.mode == .direct)
        #expect(value.totalBytes == 2_048)
    }

    @Test("目录或多选打包 tar.gz")
    func directoryOrMultipleUsesArchive() {
        let directory = ThrowEntry(name: "photos", isDirectory: true, byteSize: 10_000)
        let file = ThrowEntry(name: "notes.txt", isDirectory: false, byteSize: 100)
        #expect(payload([directory]).mode == .archive)
        #expect(payload([directory, file]).mode == .archive)
    }
}

// MARK: - 命令拼接

@Suite("投递命令")
struct ThrowCommandTests {
    @Test("单引号安全转义")
    func quotesSingleQuote() {
        #expect(ThrowCommand.quote("/tmp/a b") == "'/tmp/a b'")
        #expect(ThrowCommand.quote("a'b") == "'a'\\''b'")
    }

    @Test("远端路径的 ~ 用 $HOME 展开，其余照常转义")
    func remoteQuoteExpandsHome() {
        #expect(ThrowCommand.remoteQuote("~") == "\"$HOME\"")
        #expect(ThrowCommand.remoteQuote("~/.toss") == "\"$HOME\"/'.toss'")
        #expect(ThrowCommand.remoteQuote("~/a b") == "\"$HOME\"/'a b'")
        #expect(ThrowCommand.remoteQuote("/tmp/a b") == "'/tmp/a b'")
    }

    @Test("浏览前先建默认目录，~ 用 $HOME 展开")
    func ensureDirectoryCreatesDefaultFolder() {
        #expect(ThrowCommand.ensureDirectory("~/.toss") == "mkdir -p \"$HOME\"/'.toss'")
        #expect(ThrowCommand.ensureDirectory("/srv/data") == "mkdir -p '/srv/data'")
    }

    @Test("源端文件带 ./ 前缀，-rf 之类的名字不会被当成选项")
    func sourcePrefixesDotSlash() {
        let entry = ThrowEntry(name: "-rf", isDirectory: false, byteSize: 1)
        #expect(
            ThrowCommand.source(directory: "/tmp/a b", entries: [entry], mode: .direct)
                == "cd '/tmp/a b' && exec cat './-rf'"
        )
        #expect(
            ThrowCommand.source(directory: "/tmp", entries: [entry], mode: .archive)
                == "cd '/tmp' && exec tar -czf - './-rf'"
        )
    }

    @Test("目标端同名文件加 -2 后缀，隐藏文件也搬走")
    func moveScriptRenamesAndMovesHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-move-test-\(UUID().uuidString)")
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "old".write(to: target.appendingPathComponent("report.pdf"), atomically: true, encoding: .utf8)
        try "new".write(to: incoming.appendingPathComponent("report.pdf"), atomically: true, encoding: .utf8)
        try "note".write(to: incoming.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: incoming.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            ThrowCommand.moveScript(temp: incoming.path, target: target.path),
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("report-2.pdf").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(".env").path))
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
    }

    @Test("精确字节数按文件逐个求和")
    func exactBytesSumsFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-bytes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try "12345".write(to: first, atomically: true, encoding: .utf8)
        try "1234567".write(to: second, atomically: true, encoding: .utf8)

        let text = try runShell(ThrowCommand.exactBytes(paths: [first.path, second.path]))
        #expect(text.trimmed == "12")
    }

    @Test("浏览脚本的输出能被解析：文件取字节数，目录与隐藏文件都不漏")
    func listingParsesScriptOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-list-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "12345".write(
            to: root.appendingPathComponent("report.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "key".write(
            to: root.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try "abc".write(
            to: photos.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )

        let entries = ThrowListing.parse(try runShell(ThrowCommand.list(directory: root.path)))

        #expect(entries.count == 3)
        #expect(entries.first { $0.name == "report.txt" }?.byteSize == 5)
        #expect(entries.first { $0.name == ".env" }?.byteSize == 3)
        let folder = entries.first { $0.name == "photos" }
        #expect(folder?.isDirectory == true)
        #expect((folder?.byteSize ?? 0) >= 1024)
    }

    private func runShell(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}

// MARK: - 队列

@Suite("传输队列", .serialized)
@MainActor
struct TransferQueueTests {
    private func makeJob(_ name: String) -> TransferJob {
        TransferJob(
            source: .server(ServerConfig(name: "src", host: "127.0.0.1")),
            sourceDir: "/tmp",
            target: .local,
            targetDir: "/tmp",
            entries: [ThrowEntry(name: name, isDirectory: false, byteSize: 10)]
        )
    }

    private func waitUntilIdle(_ queue: TransferQueue) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !queue.isIdle && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // 让 report 里投递到主线程的更新落地。
        try await Task.sleep(nanoseconds: 40_000_000)
    }

    @Test("串行执行，先到的先跑")
    func runsSerially() async throws {
        final class Order {
            var names: [String] = []
        }
        let order = Order()

        let queue = TransferQueue { job, report, _ in
            report(.transferring, 0.5, 5)
            try await Task.sleep(nanoseconds: 30_000_000)
            order.names.append(job.entries[0].name)
        }

        queue.enqueue(makeJob("one"))
        queue.enqueue(makeJob("two"))
        try await waitUntilIdle(queue)

        #expect(order.names == ["one", "two"])
        #expect(queue.jobs.allSatisfy { $0.stage == .finished })
    }

    @Test("失败标记为 failed，重试后重新执行")
    func retriesAfterFailure() async throws {
        final class Attempts {
            var count = 0
        }
        let attempts = Attempts()

        let queue = TransferQueue { _, _, _ in
            attempts.count += 1
            if attempts.count == 1 {
                throw TossError("boom")
            }
        }

        let job = makeJob("retry")
        queue.enqueue(job)
        try await waitUntilIdle(queue)

        #expect(queue.jobs.first?.stage == .failed)
        #expect(queue.jobs.first?.message != nil)

        queue.retry(job.id)
        try await waitUntilIdle(queue)

        #expect(attempts.count == 2)
        #expect(queue.jobs.first?.stage == .finished)
    }

    @Test("取消正在执行的传输")
    func cancelsRunning() async throws {
        let queue = TransferQueue { _, _, cancellation in
            for _ in 0..<200 {
                if cancellation.isCancelled { throw ThrowCancelled() }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let job = makeJob("cancel")
        queue.enqueue(job)
        try await Task.sleep(nanoseconds: 20_000_000)
        queue.cancel(job.id)
        try await waitUntilIdle(queue)

        #expect(queue.jobs.first?.stage == .cancelled)
    }

    @Test("清除已完成，保留未完成的")
    func clearFinished() async throws {
        let queue = TransferQueue { _, _, _ in }
        queue.enqueue(makeJob("done"))
        try await waitUntilIdle(queue)
        #expect(queue.jobs.count == 1)

        queue.clearFinished()
        #expect(queue.jobs.isEmpty)
    }
}
