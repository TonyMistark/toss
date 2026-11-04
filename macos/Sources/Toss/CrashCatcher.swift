import AppKit
import Darwin
import Foundation

// MARK: - 处理器

/// 进程死之前那几毫秒能做的事。
///
/// 信号处理器里**不能**分配内存、不能加锁、不能碰 Swift 的字符串与对象——
/// 崩溃往往就发生在某个锁被持有的时刻，再进一次同一把锁就是死锁，进程会挂成
/// 「无响应」而不是退出，系统的崩溃日志也不会生成。所以这里只做三件事：
///
/// 1. 往一个**启动时就打开好**的文件描述符里写字节（`write` 是异步信号安全的）；
/// 2. `backtrace` / `backtrace_symbols_fd` 抓栈（同样直写 fd，不 malloc）；
/// 3. 恢复默认处理并 `raise`，让系统照旧生成 `~/Library/Logs/DiagnosticReports`
///    里的那份崩溃日志。
///
/// 格式化留到下次启动：那一刻有的是时间，而且知道版本、系统、刚才在做什么。
enum CrashCatcher {
    /// 现场文件。名字带 pid 与启动时刻，避免 pid 复用把上一次的现场覆盖掉。
    nonisolated(unsafe) private static var inflightFD: Int32 = -1
    nonisolated(unsafe) private static var inflightURL: URL?
    /// 现场文件的 C 路径。处理器里只能 `unlink`（异步信号安全），
    /// 而「URL → C 字符串」这种转换不能在里面做，所以安装时先填好。
    nonisolated(unsafe) private static var inflightPath =
        [CChar](repeating: 0, count: Int(PATH_MAX))
    /// 抓栈的缓冲区预分配：处理器里不能新建数组。
    nonisolated(unsafe) private static var frames =
        [UnsafeMutableRawPointer?](repeating: nil, count: 96)
    /// Objective-C 异常处理器已经写过现场了？随后的 SIGABRT 就只补一行信号名，
    /// 不再抓一遍栈——同一个文件里两段 `frames` 会让读者以为崩了两次。
    nonisolated(unsafe) private static var exceptionWritten = false
    nonisolated(unsafe) private static var installed = false

    /// 装上处理器。返回现场文件的位置（测试与调用方偶尔要报出来）。
    ///
    /// 测试进程里直接返回 nil：测试自己想验证崩溃行为时会主动 `raise`，
    /// 装了处理器就把信号吞掉了。
    @discardableResult
    static func install(directory: URL) -> URL? {
        guard !installed, !CrashEnvironment.isTestProcess else { return inflightURL }
        installed = true

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `.inflight-` 开头：读者在访达里看不见这一堆半成品，只看得到正式报告。
        let name = ".inflight-\(getpid())-\(Int(Date().timeIntervalSince1970)).raw"
        let url = directory.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            installed = false
            return nil
        }
        inflightFD = fd
        inflightURL = url
        keepPath(of: url)

        // 头部写一次：主二进制的加载地址（ASLR 之后的）——没有它，栈里的地址
        // 换个进程就对不上符号，`atos` 也就无从下手。
        writeString("WTMDCRASH 1\n", to: fd)
        if let base = mainImageBase() {
            writeString(String(format: "base 0x%llx\n", base), to: fd)
        }

        for number in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(number, crashSignalHandler)
        }
        // 另外三个信号**不是崩溃**：有人让它停。`killall toss`、终端里的 Ctrl-C、
        // 注销重启时系统发的 SIGTERM 都走这里。它们不跑 `atexit`，现场文件会
        // 留在盘上——下次启动就会把「别人喊停」报成「上次没有正常退出」（#143）。
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, stopSignalHandler)
        }
        NSSetUncaughtExceptionHandler { exception in
            CrashCatcher.write(exception: exception)
        }
        // 正常退出：把半成品删掉。留着只会让下次启动误报「上次没正常退出」。
        // 两道都挂上：通知管「应用退出」，`atexit` 管「进程走到头」——
        // 崩溃时 `exit` 不会被执行，`kill -9` 更不会，所以这两道都不会误吞现场。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            CrashCatcher.finishCleanly()
        }
        atexit { CrashCatcher.finishCleanly() }
        return url
    }
    /// 正常退出时调用：关掉 fd、删掉现场文件。
    static func finishCleanly() {
        if inflightFD >= 0 {
            close(inflightFD)
            inflightFD = -1
        }
        if let url = inflightURL {
            try? FileManager.default.removeItem(at: url)
            inflightURL = nil
        }
        forgetPath()
    }

    /// 把现场文件的路径存成 C 字符串，供处理器里的 `unlink` 用。
    private static func keepPath(of url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let length = min(Int(PATH_MAX) - 1, Int(strlen(path)))
            inflightPath.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                memcpy(base, path, length)
                base[length] = 0
            }
        }
    }

    /// 抹掉路径。空路径意味着「这一份已经删过了」，处理器据此跳过。
    private static func forgetPath() {
        inflightPath.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.pointee = 0
        }
    }

    /// 有人从外面喊停时只做这一件事：把现场文件删掉。**不当崩溃**。
    ///
    /// 只碰 `unlink` 与缓冲区——处理器里不能再多做事。
    static func discardInFlight() {
        inflightPath.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, base.pointee != 0 else { return }
            _ = unlink(base)
        }
    }

    // MARK: 信号

    /// 被信号打死：写下信号名、**崩溃时刻**与栈，然后把处理权交还系统。
    ///
    /// 时刻必须当场写：现场文件是启动时预建的，`harvest` 只看得到文件的创建
    /// 时间——那其实是**启动**时间。#181 的报告里 `time:` 因此写成了 11:09
    /// （启动时刻），真崩在 12:46，排查时被它带偏了半小时。
    static func write(signal sig: Int32) {
        let fd = inflightFD
        guard fd >= 0 else { return }
        if !exceptionWritten {
            writeText("kind signal\n", to: fd)
            writeText("signal ", to: fd)
            writeSignalName(sig, to: fd)
            writeText("t ", to: fd)
            writeTimestamp(to: fd)
            writeText("frames\n", to: fd)
            frames.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let count = backtrace(base, Int32(buffer.count))
                if count > 0 {
                    backtrace_symbols_fd(base, count, fd)
                }
            }
            writeText("end\n", to: fd)
        }
        fsync(fd)
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// 未捕获的 Objective-C 异常。走到这里不在信号上下文里，可以正常拼字符串；
    /// 随后系统还会补一个 SIGABRT，那个由 `write(signal:)` 认出并跳过。
    static func write(exception: NSException) {
        let fd = inflightFD
        guard fd >= 0, !exceptionWritten else { return }
        exceptionWritten = true

        var text = "kind exception\n"
        text += "exception \(exception.name.rawValue)\n"
        text += "reason \(CrashReport.oneLine(exception.reason ?? ""))\n"
        // 不在信号上下文里，可以正常格式化时刻。
        text += "t \(Int(Date().timeIntervalSince1970))\n"
        text += "frames\n"
        text += Thread.callStackSymbols.prefix(96).joined(separator: "\n")
        text += "\nend\n"
        writeString(text, to: fd)
        fsync(fd)
    }

    /// 主二进制在内存里的起始地址（ASLR 之后的）。栈里的地址减去它，才是文件里的
    /// 偏移——没有这一行，换一台机器、换一次启动，同一串地址就对不上任何符号。
    ///
    /// `__TEXT` 是第一个 `LC_SEGMENT_64`，它的 `vmaddr` 加上 slide 就是基址。
    /// 只在 `install` 里调用：解析加载命令在处理器里做不安全，也没必要。
    private static func mainImageBase() -> UInt64? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let slide = _dyld_get_image_vmaddr_slide(0)
        guard slide >= 0 else { return nil }

        var vmaddr: UInt64 = 0
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header64.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self)
            if command.pointee.cmd == UInt32(LC_SEGMENT_64) {
                // `__PAGEZERO` 排在最前面，vmaddr 是 0——它不是基址。
                let candidate = cursor
                    .assumingMemoryBound(to: segment_command_64.self).pointee.vmaddr
                if candidate > 0 {
                    vmaddr = candidate
                    break
                }
            }
            let size = Int(command.pointee.cmdsize)
            if size <= 0 { break }
            cursor = cursor.advanced(by: size)
        }
        guard vmaddr > 0 else { return nil }
        return UInt64(slide) + vmaddr
    }

    // MARK: 只碰 fd 的写

    private static func writeText(_ text: StaticString, to fd: Int32) {
        text.withUTF8Buffer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = Darwin.write(fd, base, buffer.count)
        }
    }

    /// 裸字节写：给「临时缓冲里现拼的内容」用（时间戳的数字）。
    private static func writeText(unsafe bytes: UnsafeBufferPointer<UInt8>, to fd: Int32) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        _ = Darwin.write(fd, base, bytes.count)
    }

    /// 信号名写成字面量：`String(format:)` 要分配，处理器里不能用。
    private static func writeSignalName(_ sig: Int32, to fd: Int32) {
        switch sig {
        case SIGSEGV: writeText("SIGSEGV\n", to: fd)
        case SIGABRT: writeText("SIGABRT\n", to: fd)
        case SIGBUS: writeText("SIGBUS\n", to: fd)
        case SIGILL: writeText("SIGILL\n", to: fd)
        case SIGFPE: writeText("SIGFPE\n", to: fd)
        case SIGTRAP: writeText("SIGTRAP\n", to: fd)
        default: writeText("SIG\n", to: fd)
        }
    }

    /// 当前的 Unix 秒数，写成一行十进制（结尾没有换行，调用方自己补）。
    ///
    /// `gettimeofday` 与定长栈缓冲都是异步信号安全的——不碰堆，不用 `String`。
    private static func writeTimestamp(to fd: Int32) {
        var now = timeval()
        gettimeofday(&now, nil)
        var value = UInt64(max(0, now.tv_sec))
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { buffer in
            var count = 0
            repeat {
                buffer[count] = UInt8(48 + value % 10) // '0'
                value /= 10
                count += 1
            } while value > 0
            // 数字是倒着填的：从最后一位往前写出去，正好正序。
            for index in stride(from: count - 1, through: 0, by: -1) {
                writeText(unsafe: UnsafeBufferPointer(start: buffer.baseAddress! + index, count: 1), to: fd)
            }
        }
    }

    private static func writeString(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}

/// C 里注册的那个函数：只转一手，全部逻辑在 `CrashCatcher`。
private func crashSignalHandler(_ sig: Int32) {
    CrashCatcher.write(signal: sig)
}

/// 「请停下」的那三个信号：删掉现场，然后把处理权交还系统——进程照样当场结束，
/// 只是下次启动不会再把它当成崩溃。
private func stopSignalHandler(_ sig: Int32) {
    CrashCatcher.discardInFlight()
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - 轨迹

/// 「之前发生了什么」。崩溃报告里最有用的往往不是栈，而是最后那几行：
/// 开了第几扇窗、打开的是哪一篇、是不是刚切过模式。
///
/// 每行都立刻落盘（不做缓冲）：崩在生产代码里时，内存里那点缓冲也就跟着没了。
/// 频率很低——只有窗口与文档的开关走这里，打字不走。
enum CrashBreadcrumbs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fileURL: URL?
    /// 单个文件的上限。超过就只留最后 200 行——轨迹是「最近的」历史。
    private static let maxBytes = 64 * 1024

    static func install(directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("breadcrumbs.log")
        // 上一次的记录已经进了报告（或本来就没人要）：新的一次从空白开始。
        try? "".write(to: url, atomically: true, encoding: .utf8)
        fileURL = url
    }

    /// 记一行。`nil` 之前（测试、未安装）什么都不做。
    static func note(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL else { return }
        let line = "\(clock.string(from: Date())) \(CrashReport.oneLine(text))\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        trimIfNeeded(url)
    }

    /// 读最后 `count` 行。读不到就空着——报告少一段，照样有用。
    static func tail(_ count: Int = 40) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        fileURL = nil
    }

    private static func trimIfNeeded(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > maxBytes else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: .newlines).suffix(200).joined(separator: "\n")
        try? (kept + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
