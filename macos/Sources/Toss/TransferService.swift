import Foundation

struct TossError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

/// 调用系统 scp / ssh / tar，行为与 CLI 的 file_transfer capability 保持一致。
struct TransferService {
    private static let scpPath = "/usr/bin/scp"
    private static let sshPath = "/usr/bin/ssh"
    private static let tarPath = "/usr/bin/tar"

    func send(server: ServerConfig, files: [URL], targetDir: String) async throws -> String {
        guard !files.isEmpty else {
            throw TossError(t("No files selected to send"))
        }
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw TossError(t("File does not exist: {}", file.path))
        }

        let started = Date()
        let tempRoot = try makeTempDirectory(prefix: "toss-send-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var sendPaths: [String] = []
        var displayNames: [String] = []

        for file in files {
            if isDirectory(file) {
                let sub = tempRoot.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                let archive = sub.appendingPathComponent("\(file.lastPathComponent).tar.gz")
                let result = try await runProcess(Self.tarPath, [
                    "-czf", archive.path,
                    "-C", file.deletingLastPathComponent().path,
                    file.lastPathComponent,
                ])
                guard result.code == 0 else {
                    throw TossError(t("Could not pack the folder: {}\n{}", file.lastPathComponent, result.stderr.trimmed))
                }
                sendPaths.append(archive.path)
                displayNames.append(t("{} (packed as a folder)", file.lastPathComponent))
            } else {
                sendPaths.append(file.path)
                displayNames.append(file.lastPathComponent)
            }
        }

        let remoteDir = normalizedDirectory(targetDir)
        let destination = "\(server.address):\(remoteDir)"

        var args = scpOptions(port: server.port)
        args.append(contentsOf: sendPaths)
        args.append(destination)

        let result = try await runProcess(Self.scpPath, args)
        guard result.code == 0 else {
            throw TossError(
                t("Send failed: {}\nHint: check that your SSH key is on the server (ssh-copy-id {})",
                  result.stderr.trimmed, server.address)
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        return t("✓ Sent to {} ({}s)\n  {}", destination, format(elapsed),
                 displayNames.joined(separator: t(", ")))
    }

    func pull(server: ServerConfig, remoteFile: String, outputDir: URL, targetDir: String) async throws -> String {
        let file = remoteFile.trimmed
        guard !file.isEmpty else {
            throw TossError(t("Remote file cannot be empty"))
        }

        let remotePath = file.hasPrefix("/")
            ? file
            : joinRemote(targetDir, file)
        let output = outputDir.path

        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        let started = Date()
        var args = scpOptions(port: server.port)
        args.append("\(server.address):\(remotePath)")
        args.append(output.hasSuffix("/") ? output : output + "/")

        let result = try await runProcess(Self.scpPath, args)
        guard result.code == 0 else {
            throw TossError(
                t("Pull failed: {}\nHint: check the remote file name (use Files to browse)",
                  result.stderr.trimmed)
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        let localPath = outputDir
            .appendingPathComponent((file as NSString).lastPathComponent)
            .path
        return t("✓ {}:{} → {} ({}s)", server.address, remotePath, localPath, format(elapsed))
    }

    func list(server: ServerConfig, targetDir: String) async throws -> String {
        let dir = targetDir.trimmed
        guard !dir.isEmpty else {
            throw TossError(t("Transfer folder cannot be empty"))
        }

        var args = sshOptions(port: server.port)
        args.append(server.address)
        args.append(contentsOf: ["ls", "-lh", dir])

        let result = try await runProcess(Self.sshPath, args)
        guard result.code == 0 else {
            throw TossError(
                t("Listing failed: {}\nHint: check the server address and SSH key (ssh {})",
                  result.stderr.trimmed, server.address)
            )
        }

        let output = result.stdout.trimmed
        let displayDir = normalizedDirectory(dir)
        if output.isEmpty {
            return t("{}:{} is empty", server.address, displayDir)
        }
        return "\(server.address):\(displayDir)\n\(output)"
    }

    // MARK: - 命令拼接

    private func scpOptions(port: Int) -> [String] {
        var args = baseSSHOptions()
        if port != 22 {
            args.append(contentsOf: ["-P", "\(port)"])
        }
        return args
    }

    private func sshOptions(port: Int) -> [String] {
        var args = baseSSHOptions()
        if port != 22 {
            args.append(contentsOf: ["-p", "\(port)"])
        }
        return args
    }

    /// GUI 进程没有终端，用 BatchMode 让认证失败时快速返回而不是挂起；
    /// accept-new 让首次连接自动写入 known_hosts。
    private func baseSSHOptions() -> [String] {
        ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
    }

    private func normalizedDirectory(_ dir: String) -> String {
        let value = dir.trimmed
        return value.hasSuffix("/") ? value : value + "/"
    }

    private func joinRemote(_ dir: String, _ file: String) -> String {
        let base = dir.trimmed
        if base.hasSuffix("/") {
            return base + file
        }
        return base + "/" + file
    }

    private func format(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 子进程执行

    private struct ProcessResult {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw TossError(t("System command not found: {}", executable))
        }

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

                    continuation.resume(returning: ProcessResult(
                        code: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    ))
                } catch {
                    continuation.resume(throwing: TossError(
                        t("Could not run {}: {}", executable, error.localizedDescription)
                    ))
                }
            }
        }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
