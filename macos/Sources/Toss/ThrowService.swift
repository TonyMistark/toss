import Foundation

/// 投递的执行层：浏览源目录、在两台服务器之间打流、或落到本机。
/// 所有远端命令都从 `ThrowCommand` 生成，避免手拼引号。
struct ThrowService {
    private static let sshPath = "/usr/bin/ssh"
    private static let shPath = "/bin/sh"
    private static let tarPath = "/usr/bin/tar"

    typealias Report = (TransferStage, Double?, Int64?) -> Void

    // MARK: - 浏览

    func browse(source: ThrowTarget, directory: String) async throws -> [ThrowEntry] {
        switch source {
        case .server(let server):
            return try await browse(server: server, directory: directory)
        case .local:
            return try browseLocal(directory: directory)
        }
    }

    func browse(server: ServerConfig, directory: String) async throws -> [ThrowEntry] {
        let dir = directory.trimmed
        guard !dir.isEmpty else {
            throw TossError(t("Transfer folder cannot be empty"))
        }

        let script = "\(ThrowCommand.ensureDirectory(dir)) && \(ThrowCommand.list(directory: dir))"
        let result = try await runSSH(server, script)
        guard result.code == 0 else {
            throw TossError(
                t("Listing failed: {}\nHint: check the server address and SSH key (ssh {})",
                  result.stderr.trimmed, server.address)
            )
        }

        return ThrowListing.parse(result.stdout)
    }

    /// 本机目录直接用 FileManager 列，不用起子进程。
    func browseLocal(directory: String) throws -> [ThrowEntry] {
        let dir = directory.trimmed
        guard !dir.isEmpty else {
            throw TossError(t("Transfer folder cannot be empty"))
        }

        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            var entries: [ThrowEntry] = []
            for name in names {
                let item = url.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
                else { continue }

                let bytes: Int64
                if isDirectory.boolValue {
                    bytes = exactLocalBytes(item)
                } else {
                    bytes = Int64(
                        (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    )
                }
                entries.append(ThrowEntry(
                    name: name,
                    isDirectory: isDirectory.boolValue,
                    byteSize: bytes
                ))
            }
            return entries.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            throw TossError(t("Could not list the folder: {}", error.localizedDescription))
        }
    }

    // MARK: - 执行

    func run(_ job: TransferJob, cancellation: ThrowCancellation, report: @escaping Report) async throws {
        if cancellation.isCancelled { throw ThrowCancelled() }

        switch (job.source, job.target) {
        case (.server, .local):
            try await deliverToLocal(job, cancellation: cancellation, report: report)
        case (.server(let source), .server(let destination)):
            try await relay(
                job,
                source: source,
                destination: destination,
                cancellation: cancellation,
                report: report
            )
        case (.local, .server(let destination)):
            try await upload(job, destination: destination, cancellation: cancellation, report: report)
        case (.local, .local):
            throw TossError(t("This Mac cannot throw to itself"))
        }
    }

    // MARK: - A → B：本机中转的两条 SSH 管道

    private func relay(
        _ job: TransferJob,
        source: ServerConfig,
        destination: ServerConfig,
        cancellation: ThrowCancellation,
        report: @escaping Report
    ) async throws {
        let targetDir = job.targetDir.trimmed
        guard !targetDir.isEmpty else {
            throw TossError(t("Transfer folder cannot be empty"))
        }
        guard !job.entries.isEmpty else {
            throw TossError(t("No files selected to send"))
        }

        let tempDir = ThrowCommand.join(targetDir, ".toss-incoming-\(UUID().uuidString)")

        let prepare = try await runSSH(
            destination,
            "mkdir -p \(ThrowCommand.remoteQuote(targetDir)) \(ThrowCommand.remoteQuote(tempDir))"
        )
        try requireSuccess(
            prepare,
            cancellation: cancellation,
            message: t("Could not prepare the destination: {}", prepare.stderr.trimmed)
        )
        OperationLog.success(t("Prepared {} on {}", targetDir, destination.name))

        do {
            report(.transferring, nil, 0)

            let sourceCommand = ThrowCommand.source(
                directory: job.sourceDir,
                entries: job.entries,
                mode: job.mode
            )
            let destinationCommand = ThrowCommand.destination(
                root: tempDir,
                entries: job.entries,
                mode: job.mode
            )

            let streamed = try await stream(
                source: .remote(source),
                sourceCommand: sourceCommand,
                destination: destination,
                destinationCommand: destinationCommand,
                localFile: nil,
                expectedBytes: job.totalBytes,
                showProgress: job.mode == .direct,
                cancellation: cancellation,
                report: report
            )

            if cancellation.isCancelled { throw ThrowCancelled() }
            try checkStream(streamed, cancellation: cancellation)

            if job.mode == .archive {
                report(.unpacking, nil, nil)
            }
            report(.verifying, nil, nil)

            let sourceBytes = try await exactBytes(
                source,
                paths: job.entries.map { ThrowCommand.join(job.sourceDir, $0.name) }
            )
            let destinationBytes = try await exactBytes(destination, paths: [tempDir])

            if cancellation.isCancelled { throw ThrowCancelled() }
            guard sourceBytes == destinationBytes else {
                throw TossError(t("Verification failed: source {} bytes, destination {} bytes",
                                  sourceBytes, destinationBytes))
            }
            OperationLog.info(t("Verified {} bytes", destinationBytes))

            let move = try await runSSH(
                destination,
                ThrowCommand.moveScript(temp: tempDir, target: targetDir)
            )
            try requireSuccess(
                move,
                cancellation: cancellation,
                message: t("Could not move the transfer into place: {}", move.stderr.trimmed)
            )
            OperationLog.success(t("Placed into {}", targetDir))

            report(.finished, 1, destinationBytes)
        } catch {
            _ = try? await runSSH(destination, "rm -rf \(ThrowCommand.remoteQuote(tempDir))")
            OperationLog.warning(t("Removed temporary folder {}", tempDir))
            throw error
        }
    }

    // MARK: - A → 本机

    private func deliverToLocal(
        _ job: TransferJob,
        cancellation: ThrowCancellation,
        report: @escaping Report
    ) async throws {
        let rawDir = job.targetDir.trimmed
        let expanded = ((rawDir.isEmpty ? LocalDelivery.directory : rawDir) as NSString).expandingTildeInPath
        let destination = URL(fileURLWithPath: expanded)

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            OperationLog.info(t("Prepared {} on {}", expanded, t("This Mac")))
        } catch {
            throw TossError(t("Could not create the target folder: {}", error.localizedDescription))
        }

        let tempRoot = try makeTempDirectory(prefix: "toss-incoming-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        guard case .server(let source) = job.source else {
            throw TossError(t("This Mac cannot throw to itself"))
        }

        report(.transferring, nil, 0)

        let sourceCommand = ThrowCommand.source(
            directory: job.sourceDir,
            entries: job.entries,
            mode: job.mode
        )

        let payloadURL: URL
        if job.mode == .direct {
            let name = job.entries[0].name
            payloadURL = tempRoot.appendingPathComponent(name)
            let streamed = try await stream(
                source: .remote(source),
                sourceCommand: sourceCommand,
                destination: nil,
                destinationCommand: "",
                localFile: payloadURL,
                expectedBytes: job.totalBytes,
                showProgress: true,
                cancellation: cancellation,
                report: report
            )
            if cancellation.isCancelled { throw ThrowCancelled() }
            try checkStream(streamed, cancellation: cancellation)
        } else {
            let archive = tempRoot.appendingPathComponent("payload.tar.gz")
            let streamed = try await stream(
                source: .remote(source),
                sourceCommand: sourceCommand,
                destination: nil,
                destinationCommand: "",
                localFile: archive,
                expectedBytes: job.totalBytes,
                showProgress: false,
                cancellation: cancellation,
                report: report
            )
            if cancellation.isCancelled { throw ThrowCancelled() }
            try checkStream(streamed, cancellation: cancellation)

            report(.unpacking, nil, nil)
            let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let unpack = try await runProcess(Self.tarPath, ["-xzf", archive.path, "-C", extractDir.path])
            if cancellation.isCancelled { throw ThrowCancelled() }
            guard unpack.code == 0 else {
                throw TossError(t("Could not unpack the transfer: {}", unpack.stderr.trimmed))
            }
            payloadURL = extractDir
        }

        report(.verifying, nil, nil)

        let sourceBytes = try await exactBytes(
            source,
            paths: job.entries.map { ThrowCommand.join(job.sourceDir, $0.name) }
        )
        let localBytes = exactLocalBytes(payloadURL)

        if cancellation.isCancelled { throw ThrowCancelled() }
        guard sourceBytes == localBytes else {
            throw TossError(t("Verification failed: source {} bytes, destination {} bytes",
                              sourceBytes, localBytes))
        }

        OperationLog.info(t("Verified {} bytes", sourceBytes))

        if job.mode == .direct {
            try moveFile(payloadURL, into: destination)
        } else {
            try moveContents(of: payloadURL, into: destination)
        }
        OperationLog.success(t("Placed into {}", destination.path))

        report(.finished, 1, sourceBytes)
    }

    // MARK: - 本机 → 服务器：本机打包，管道送进 SSH

    private func upload(
        _ job: TransferJob,
        destination: ServerConfig,
        cancellation: ThrowCancellation,
        report: @escaping Report
    ) async throws {
        let targetDir = job.targetDir.trimmed
        guard !targetDir.isEmpty else {
            throw TossError(t("Transfer folder cannot be empty"))
        }
        guard !job.entries.isEmpty else {
            throw TossError(t("No files selected to send"))
        }

        let tempDir = ThrowCommand.join(targetDir, ".toss-incoming-\(UUID().uuidString)")

        let prepare = try await runSSH(
            destination,
            "mkdir -p \(ThrowCommand.remoteQuote(targetDir)) \(ThrowCommand.remoteQuote(tempDir))"
        )
        try requireSuccess(
            prepare,
            cancellation: cancellation,
            message: t("Could not prepare the destination: {}", prepare.stderr.trimmed)
        )
        OperationLog.success(t("Prepared {} on {}", targetDir, destination.name))

        do {
            report(.transferring, nil, 0)

            let sourceCommand = ThrowCommand.source(
                directory: job.sourceDir,
                entries: job.entries,
                mode: job.mode
            )
            let destinationCommand = ThrowCommand.destination(
                root: tempDir,
                entries: job.entries,
                mode: job.mode
            )

            let streamed = try await stream(
                source: .local,
                sourceCommand: sourceCommand,
                destination: destination,
                destinationCommand: destinationCommand,
                localFile: nil,
                expectedBytes: job.totalBytes,
                showProgress: job.mode == .direct,
                cancellation: cancellation,
                report: report
            )

            if cancellation.isCancelled { throw ThrowCancelled() }
            try checkStream(streamed, cancellation: cancellation)

            if job.mode == .archive {
                report(.unpacking, nil, nil)
            }
            report(.verifying, nil, nil)

            let sourceBytes = localSourceBytes(
                directory: job.sourceDir,
                entries: job.entries
            )
            let destinationBytes = try await exactBytes(destination, paths: [tempDir])

            if cancellation.isCancelled { throw ThrowCancelled() }
            guard sourceBytes == destinationBytes else {
                throw TossError(t("Verification failed: source {} bytes, destination {} bytes",
                                  sourceBytes, destinationBytes))
            }
            OperationLog.info(t("Verified {} bytes", destinationBytes))

            let move = try await runSSH(
                destination,
                ThrowCommand.moveScript(temp: tempDir, target: targetDir)
            )
            try requireSuccess(
                move,
                cancellation: cancellation,
                message: t("Could not move the transfer into place: {}", move.stderr.trimmed)
            )
            OperationLog.success(t("Placed into {}", targetDir))

            report(.finished, 1, destinationBytes)
        } catch {
            _ = try? await runSSH(destination, "rm -rf \(ThrowCommand.remoteQuote(tempDir))")
            OperationLog.warning(t("Removed temporary folder {}", tempDir))
            throw error
        }
    }

    // MARK: - 字节校验

    private func localSourceBytes(directory: String, entries: [ThrowEntry]) -> Int64 {
        entries.reduce(0) { total, entry in
            let path = (ThrowCommand.join(directory, entry.name) as NSString).expandingTildeInPath
            return total + exactLocalBytes(URL(fileURLWithPath: path))
        }
    }

    private func exactBytes(_ server: ServerConfig, paths: [String]) async throws -> Int64 {
        guard !paths.isEmpty else { return 0 }
        let result = try await runSSH(server, ThrowCommand.exactBytes(paths: paths))
        guard result.code == 0 else {
            throw TossError(t("Could not verify the transfer: {}", result.stderr.trimmed))
        }
        return Int64(result.stdout.trimmed) ?? 0
    }

    private func exactLocalBytes(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        )
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - 本机落盘

    private func moveFile(_ file: URL, into directory: URL) throws {
        let existing = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        )
        let name = FileNaming.uniqueName(for: file.lastPathComponent, existing: existing)
        try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(name))
    }

    private func moveContents(of source: URL, into destination: URL) throws {
        var existing = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        )
        let items = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in items {
            let name = FileNaming.uniqueName(for: item.lastPathComponent, existing: existing)
            try FileManager.default.moveItem(at: item, to: destination.appendingPathComponent(name))
            existing.insert(name)
        }
    }

    // MARK: - 管道

    private struct StreamResult {
        var sourceCode: Int32
        var sourceError: String
        var destinationCode: Int32
        var destinationError: String
    }

    private struct ProcessResult {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    /// 流的源头：远端 SSH 进程，或本机 `/bin/sh`。
    private enum SourceEndpoint {
        case remote(ServerConfig)
        case local
    }

    private func stream(
        source: SourceEndpoint,
        sourceCommand: String,
        destination: ServerConfig?,
        destinationCommand: String,
        localFile: URL?,
        expectedBytes: Int64,
        showProgress: Bool,
        cancellation: ThrowCancellation,
        report: @escaping Report
    ) async throws -> StreamResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.streamSync(
                        source: source,
                        sourceCommand: sourceCommand,
                        destination: destination,
                        destinationCommand: destinationCommand,
                        localFile: localFile,
                        expectedBytes: expectedBytes,
                        showProgress: showProgress,
                        cancellation: cancellation,
                        report: report
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func streamSync(
        source: SourceEndpoint,
        sourceCommand: String,
        destination: ServerConfig?,
        destinationCommand: String,
        localFile: URL?,
        expectedBytes: Int64,
        showProgress: Bool,
        cancellation: ThrowCancellation,
        report: @escaping Report
    ) throws -> StreamResult {
        guard !cancellation.isCancelled else { throw ThrowCancelled() }

        let stderrRoot = try makeTempDirectory(prefix: "toss-stream-")
        defer { try? FileManager.default.removeItem(at: stderrRoot) }

        let sourceErrURL = stderrRoot.appendingPathComponent("source.stderr")
        let destinationErrURL = stderrRoot.appendingPathComponent("destination.stderr")
        FileManager.default.createFile(atPath: sourceErrURL.path, contents: nil)
        FileManager.default.createFile(atPath: destinationErrURL.path, contents: nil)

        let sourceOut = Pipe()
        let destinationIn = destination == nil ? nil : Pipe()

        let sourceErr = try FileHandle(forWritingTo: sourceErrURL)
        let sourceProcess = Process()
        switch source {
        case .remote(let server):
            sourceProcess.executableURL = URL(fileURLWithPath: Self.sshPath)
            sourceProcess.arguments = sshOptions(port: server.port) + [server.address, sourceCommand]
        case .local:
            sourceProcess.executableURL = URL(fileURLWithPath: Self.shPath)
            sourceProcess.arguments = ["-c", sourceCommand]
            sourceProcess.environment = ProcessInfo.processInfo.environment
        }
        sourceProcess.standardOutput = sourceOut
        sourceProcess.standardError = sourceErr

        var destinationProcess: Process?
        var destinationErr: FileHandle?

        if let destination, let destinationIn {
            FileManager.default.createFile(atPath: destinationErrURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationErrURL)
            destinationErr = handle

            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.sshPath)
            process.arguments = sshOptions(port: destination.port) + [destination.address, destinationCommand]
            process.standardInput = destinationIn
            process.standardError = handle
            destinationProcess = process
        }

        var localHandle: FileHandle?
        if let localFile {
            FileManager.default.createFile(atPath: localFile.path, contents: nil)
            localHandle = try FileHandle(forWritingTo: localFile)
        }

        do {
            try sourceProcess.run()
            cancellation.register(sourceProcess)
            if let destinationProcess {
                try destinationProcess.run()
                cancellation.register(destinationProcess)
            }
        } catch {
            sourceProcess.terminate()
            destinationProcess?.terminate()
            sourceErr.closeFile()
            destinationErr?.closeFile()
            localHandle?.closeFile()
            throw TossError(t("Could not start the transfer: {}", error.localizedDescription))
        }

        OperationLog.info(t("Stream source: {}", LogFormat.truncate(sourceCommand, 360)))
        if let destination {
            OperationLog.info(t("Stream destination ({}): {}", destination.name,
                                LogFormat.truncate(destinationCommand, 360)))
        }

        let readHandle = sourceOut.fileHandleForReading
        let writeHandle = localHandle ?? destinationIn?.fileHandleForWriting

        var count: Int64 = 0
        var writeFailed = false
        var lastReport = Date.distantPast

        while !cancellation.isCancelled {
            let data = readHandle.readData(ofLength: 65536)
            if data.isEmpty { break }

            if let writeHandle {
                do {
                    try writeHandle.write(contentsOf: data)
                } catch {
                    writeFailed = true
                    break
                }
            }

            count += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.25 {
                lastReport = now
                let progress = showProgress && expectedBytes > 0
                    ? min(0.98, Double(count) / Double(expectedBytes))
                    : nil
                report(.transferring, progress, count)
            }
        }

        try? writeHandle?.close()
        try? readHandle.close()

        if writeFailed || cancellation.isCancelled {
            sourceProcess.terminate()
            destinationProcess?.terminate()
        }

        sourceProcess.waitUntilExit()
        destinationProcess?.waitUntilExit()
        cancellation.unregister(sourceProcess)
        if let destinationProcess {
            cancellation.unregister(destinationProcess)
        }

        sourceErr.closeFile()
        destinationErr?.closeFile()

        let progress = showProgress && expectedBytes > 0 && !cancellation.isCancelled
            ? min(0.99, Double(count) / Double(expectedBytes))
            : nil
        report(.transferring, progress, count)

        let sourceCode = sourceProcess.terminationStatus
        let destinationCode = destinationProcess?.terminationStatus ?? 0
        let sourceErrorText = readText(sourceErrURL)
        let destinationErrorText = readText(destinationErrURL)

        if sourceCode == 0 && destinationCode == 0 {
            OperationLog.success(t("Stream finished: {}", ByteCount.format(count)))
        } else {
            OperationLog.error(t("Stream failed ({} / {}): {}", sourceCode, destinationCode,
                                 LogFormat.truncate((sourceErrorText + destinationErrorText).trimmed, 400)))
        }

        return StreamResult(
            sourceCode: sourceCode,
            sourceError: sourceErrorText,
            destinationCode: destinationCode,
            destinationError: destinationErrorText
        )
    }

    private func readText(_ url: URL) -> String {
        (try? Data(contentsOf: url))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: - 子进程

    private func runSSH(_ server: ServerConfig, _ script: String) async throws -> ProcessResult {
        try await runProcess(Self.sshPath, sshOptions(port: server.port) + [server.address, script])
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            OperationLog.error(t("System command not found: {}", executable))
            throw TossError(t("System command not found: {}", executable))
        }

        let command = LogFormat.truncate(([executable] + arguments).joined(separator: " "), 400)
        OperationLog.info(t("Run: {}", command))

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("toss-run-\(UUID().uuidString)")

                do {
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    let stdoutURL = tempDir.appendingPathComponent("stdout")
                    let stderrURL = tempDir.appendingPathComponent("stderr")
                    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

                    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
                    process.standardOutput = stdoutHandle
                    process.standardError = stderrHandle

                    try process.run()
                    process.waitUntilExit()
                    try? stdoutHandle.close()
                    try? stderrHandle.close()

                    let stdout = (try? Data(contentsOf: stdoutURL))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let stderr = (try? Data(contentsOf: stderrURL))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""

                    if process.terminationStatus == 0 {
                        OperationLog.success(t("Done (exit {}): {}", process.terminationStatus,
                                               LogFormat.truncate(command, 140)))
                    } else {
                        OperationLog.error(t("Exit {}: {}", process.terminationStatus,
                                            LogFormat.truncate(stderr.trimmed, 320)))
                    }

                    continuation.resume(returning: ProcessResult(
                        code: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    ))
                } catch {
                    OperationLog.error(t("Could not run {}: {}", executable, error.localizedDescription))
                    continuation.resume(throwing: TossError(
                        t("Could not run {}: {}", executable, error.localizedDescription)
                    ))
                }
            }
        }
    }

    private func checkStream(_ streamed: StreamResult, cancellation: ThrowCancellation) throws {
        if cancellation.isCancelled { throw ThrowCancelled() }

        let sourceDetail = streamed.sourceError.trimmed
        let destinationDetail = streamed.destinationError.trimmed

        if streamed.sourceCode != 0, !sourceDetail.isEmpty {
            throw TossError(t("Transfer failed: {}", sourceDetail))
        }
        if streamed.destinationCode != 0, !destinationDetail.isEmpty {
            throw TossError(t("Transfer failed: {}", destinationDetail))
        }
        if streamed.sourceCode != 0 || streamed.destinationCode != 0 {
            let code = streamed.sourceCode != 0 ? streamed.sourceCode : streamed.destinationCode
            throw TossError(t("Transfer failed with exit code {}", code))
        }
    }

    private func requireSuccess(
        _ result: ProcessResult,
        cancellation: ThrowCancellation,
        message: String
    ) throws {
        if cancellation.isCancelled { throw ThrowCancelled() }
        guard result.code == 0 else {
            let detail = result.stderr.trimmed
            throw TossError(detail.isEmpty ? message : detail)
        }
    }

    private func sshOptions(port: Int) -> [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
        ]
        if port != 22 {
            args.append(contentsOf: ["-p", "\(port)"])
        }
        return args
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
