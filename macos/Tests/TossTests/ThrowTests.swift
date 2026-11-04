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

// MARK: - 传输方式

@Suite("投递计划")
struct ThrowPlanTests {
    private let server = ServerConfig(name: "prod", host: "10.0.0.1")

    private func payload(_ entries: [ThrowEntry]) -> ThrowPayload {
        ThrowPayload(source: server, sourceDir: "/srv", entries: entries)
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
            source: ServerConfig(name: "src", host: "127.0.0.1"),
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
