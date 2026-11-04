import Foundation

// MARK: - 环境

/// 报告里「这台机器是什么样」的那几行。
///
/// 全是只读的一次性查询：版本号来自 Info.plist（`swift run` 时没有 bundle，
/// 退回 `dev`），系统版本拼成 `macOS 15.5`，架构在编译期就定了。
enum CrashEnvironment {
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String
        guard let version, !version.isEmpty else { return "dev" }
        return version
    }

    /// 开发版（`swift run`、`.build/debug/toss`）：没有 bundle 版本号。
    /// 它们的现场另存一本账，不混进读者的崩溃面板（#147）。
    static var isDevelopmentBuild: Bool { appVersion == "dev" }

    static var systemDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        return text
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// 测试进程里绝不装信号处理器：那会把测试自己的崩溃吞掉，也会写真实的
    /// 应用支持目录。判定方式与 `L10n` 一致——两个测试跑器留下的痕迹不同。
    static var isTestProcess: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let path = Bundle.main.bundlePath + "/" + (CommandLine.arguments.first ?? "")
        return path.contains("xctest") || path.contains("swiftpm")
    }
}

// MARK: - 现场原文

/// 信号处理器当场写下的那几个字段。它是**原始材料**：进程死之前能写的只有这些
/// （不能分配内存、不能格式化字符串），版本、系统、轨迹都在下次启动时才补上。
struct CrashRaw: Equatable {
    /// 处理器写下的种类；`nil` 表示只有头部——进程没来得及写任何现场
    /// （强制退出、`kill -9`、断电）。这个区别不能省：抓栈失败时帧同样为空，
    /// 但那种情况是**真崩溃**，不能报成「被外部结束」。
    var kind: CrashReport.Kind?
    var signal: String?
    var exceptionName: String?
    var exceptionReason: String?
    /// 崩溃时刻（Unix 秒）。信号处理器当场写下；旧格式没有这行，回退文件创建时间。
    var unixSeconds: UInt64?
    var frames: [String] = []

    /// 读 `.inflight-*.raw`。宽容优先：多一行少一行都不该让报告丢掉。
    static func parse(_ text: String) -> CrashRaw {
        var raw = CrashRaw()
        var inFrames = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "frames" {
                inFrames = true
                continue
            }
            if trimmed == "end" { break }
            if inFrames {
                raw.frames.append(line)
                continue
            }
            if trimmed.hasPrefix("kind ") {
                raw.kind = CrashReport.Kind(rawValue: String(trimmed.dropFirst(5))) ?? .signal
            } else if trimmed.hasPrefix("signal ") {
                raw.signal = String(trimmed.dropFirst(7))
            } else if trimmed.hasPrefix("exception ") {
                raw.exceptionName = String(trimmed.dropFirst(10))
                raw.kind = .exception
            } else if trimmed.hasPrefix("reason ") {
                raw.exceptionReason = String(trimmed.dropFirst(7))
            } else if trimmed.hasPrefix("t "), let seconds = UInt64(trimmed.dropFirst(2)) {
                raw.unixSeconds = seconds
            }
        }
        return raw
    }
}

// MARK: - 报告

/// 一份崩溃报告：文件长什么样、怎么读回来、怎么变成一段能贴进 issue 的话。
///
/// 文件是**纯文本 markdown**，开头一段 HTML 注释装元数据。两个理由：读者
/// 用任何编辑器都打得开（也就能直接发给人看），而面板要靠那几个字段排版。
/// 注释在 GitHub 上不渲染，贴进 issue 不会露出来。
struct CrashReport: Identifiable, Equatable {
    enum Kind: String {
        /// 被信号打死：SIGSEGV、SIGABRT、SIGILL……
        case signal
        /// 未捕获的 Objective-C 异常（通常紧接着 SIGABRT）。
        case exception
        /// 上次没有正常退出，但也没留下现场——强退、断电、`kill -9`。
        case terminated
        /// 读者自己点「报告问题」写的。
        case feedback
    }

    let id: String
    let capturedAt: Date
    let kind: Kind
    let signal: String?
    let appVersion: String
    let system: String
    let architecture: String
    let windowCount: Int?
    let documentName: String?
    /// 完整正文（含头部注释）。面板显示它，剪贴板复制它。
    let markdown: String
    /// 落盘位置。还没写下去的为 nil。
    var fileURL: URL?

    // MARK: 人话

    var headline: String {
        switch kind {
        case .signal: return t("Toss crashed")
        case .exception: return t("Toss crashed")
        case .terminated: return t("Toss did not shut down normally")
        case .feedback: return t("Report a Problem")
        }
    }

    var iconName: String {
        switch kind {
        case .signal, .exception: return "exclamationmark.triangle.fill"
        case .terminated: return "power"
        case .feedback: return "exclamationmark.bubble"
        }
    }

    /// 一句话解释「这一串大写字母是什么意思」。写给不写代码的人看。
    var explanation: String {
        switch kind {
        case .exception:
            let name = exceptionNameFromMarkdown ?? "NSException"
            return t("An unexpected condition stopped the app ({}).", name)
        case .terminated:
            return t("No crash detail was captured — the app was stopped from outside (force quit, `kill`, a restart or a power cut).")
        case .feedback:
            return t("Written from inside the app.")
        case .signal:
            let name = signal ?? "signal"
            return "\(name) — \(Self.explain(signal: name))"
        }
    }

    /// 常见信号的通俗解释。认不出的就说认不出，不编。
    static func explain(signal name: String) -> String {
        switch name {
        case "SIGSEGV":
            return t("it read or wrote memory it does not own — usually a nil or already-freed object.")
        case "SIGABRT":
            return t("it was stopped on purpose after an internal check failed.")
        case "SIGBUS":
            return t("memory access went wrong at the hardware level.")
        case "SIGILL":
            return t("it hit an instruction it cannot execute — Swift's `fatalError` lands here.")
        case "SIGFPE":
            return t("an arithmetic operation failed.")
        case "SIGTRAP":
            return t("a trap was raised — a debugger or an assertion.")
        default:
            return t("the system stopped it.")
        }
    }

    /// 「2026-10-20 15:03 · toss 0.13.0 · macOS 15.5 · 3 扇窗口」
    var summaryLine: String {
        var parts = [Self.stampFormatter.string(from: capturedAt), "Toss \(appVersion)", system]
        if let windowCount, windowCount > 1 {
            parts.append(t("{} windows", windowCount))
        }
        return parts.joined(separator: " · ")
    }

    var suggestedIssueTitle: String {
        switch kind {
        case .feedback:
            return t("[Feedback] ") + (documentName ?? "")
        case .terminated:
            // 没有栈、没有信号——这不是崩溃，是有人把进程结束了。标题不该
            // 让人以为是应用自己出了问题。
            return t("[Exit] Toss ended without a clean quit · v")
                + appVersion
        default:
            return t("[Crash] ") + (signal ?? kind.rawValue) + " · v" + appVersion
        }
    }

    // MARK: 读写

    /// 拼一份报告：元数据注释 + 正文。
    static func make(
        id: String = CrashReport.newID(),
        capturedAt: Date = Date(),
        kind: Kind,
        signal: String? = nil,
        appVersion: String = CrashEnvironment.appVersion,
        system: String = CrashEnvironment.systemDescription,
        architecture: String = CrashEnvironment.architecture,
        windowCount: Int? = nil,
        documentName: String? = nil,
        body: String,
        fileURL: URL? = nil
    ) -> CrashReport {
        var header = "<!-- toss-crash v1\n"
        header += "id: \(id)\n"
        header += "time: \(isoFormatter.string(from: capturedAt))\n"
        header += "kind: \(kind.rawValue)\n"
        if let signal { header += "signal: \(signal)\n" }
        header += "version: \(appVersion)\n"
        header += "system: \(system)\n"
        header += "arch: \(architecture)\n"
        if let windowCount { header += "windows: \(windowCount)\n" }
        if let documentName { header += "document: \(oneLine(documentName))\n" }
        header += "-->\n\n"

        return CrashReport(
            id: id, capturedAt: capturedAt, kind: kind, signal: signal,
            appVersion: appVersion, system: system, architecture: architecture,
            windowCount: windowCount, documentName: documentName,
            markdown: header + body, fileURL: fileURL
        )
    }

    /// 从文件读回来。字段缺一两个不致命：面板少显示一行，总比装作没有这份报告好。
    static func parse(_ text: String, fileURL: URL? = nil) -> CrashReport? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("<!-- toss-crash") }) else {
            return nil
        }
        var fields: [String: String] = [:]
        for line in lines[(start + 1)...] {
            if line.hasPrefix("-->") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let id = fields["id"] else { return nil }
        let kind = Kind(rawValue: fields["kind"] ?? "") ?? .signal
        let capturedAt = fields["time"].flatMap { isoFormatter.date(from: $0) }
            ?? fileURL.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
            ?? Date()

        return CrashReport(
            id: id, capturedAt: capturedAt, kind: kind, signal: fields["signal"],
            appVersion: fields["version"] ?? "dev",
            system: fields["system"] ?? "",
            architecture: fields["arch"] ?? "",
            windowCount: fields["windows"].flatMap(Int.init),
            documentName: fields["document"],
            markdown: text, fileURL: fileURL
        )
    }

    /// 正文里那行「异常：Name」，供 `explanation` 用。两种语言的正文都认。
    private var exceptionNameFromMarkdown: String? {
        for line in markdown.components(separatedBy: .newlines) where line.hasPrefix("- ") {
            guard line.contains("异常") || line.contains("Exception") else { continue }
            let value = line.split(whereSeparator: { $0 == "：" || $0 == ":" })
            return value.last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: 正文装配

    /// 崩溃报告的正文。**不含正文内容**——只报窗口数、文件名、栈与轨迹。
    ///
    /// `kind` 决定时间标签：信号与异常的 `capturedAt` 是当场写下的崩溃时刻；
    /// 「没正常退出」的 `capturedAt` 只能取现场文件的创建时间——那是**启动**
    /// 时刻（#181），写成「时间」会让人以为进程死在那一刻，所以叫「最后活动」。
    /// `appVersion` 是死去那位的版本（轨迹里自报的），不是收报告这位的。
    static func crashBody(
        raw: CrashRaw,
        breadcrumbs: [String],
        capturedAt: Date,
        kind: Kind,
        appVersion: String = CrashEnvironment.appVersion
    ) -> String {
        var body = "# \(t("toss crash report"))\n\n"
        let timeLabel = kind == .terminated ? t("Last seen") : t("Time")
        body += "- \(timeLabel)\(Self.colon)\(stampFormatter.string(from: capturedAt))\n"
        body += "- \(t("Version"))\(Self.colon)\(appVersion)"
            + "（\(CrashEnvironment.architecture)）\n"
        body += "- \(t("System"))\(Self.colon)\(CrashEnvironment.systemDescription)\n"
        if let exception = raw.exceptionName {
            body += "- \(t("Exception"))\(Self.colon)\(exception)\n"
            if let reason = raw.exceptionReason, !reason.isEmpty {
                body += "- \(t("Reason"))\(Self.colon)\(oneLine(reason))\n"
            }
        } else if let signal = raw.signal {
            body += "- \(t("Signal"))\(Self.colon)\(signal)\n"
        }
        if let windows = windowCount(in: breadcrumbs) {
            body += "- \(t("Windows open"))\(Self.colon)\(windows)\n"
        }
        if let document = documentName(in: breadcrumbs) {
            body += "- \(t("Document"))\(Self.colon)\(document)\n"
        }

        body += "\n## \(t("What happened"))\n\n"
        if raw.frames.isEmpty {
            if kind == .terminated {
                body += t("Nothing was captured: the process went away without a chance to write — force quit, `kill -9`, a power loss or a panic.")
            } else {
                body += t("The failure was recorded, but no call stack was captured.")
            }
            body += "\n"
        } else {
            let name = raw.signal ?? t("an unknown signal")
            body += "\(name) — \(explain(signal: name))\n"
            body += "\n## \(t("Call stack"))\n\n```\n"
            body += raw.frames.prefix(80).joined(separator: "\n")
            body += "\n```\n"
        }

        if !breadcrumbs.isEmpty {
            body += "\n## \(t("What led up to it"))\n\n```\n"
            body += breadcrumbs.suffix(40).joined(separator: "\n")
            body += "\n```\n"
        }

        body += "\n---\n"
        body += t("Collected locally by toss. It contains no writing from your documents — only versions, window counts, file names, and the stack.")
        return body
    }

    /// 标签后面那个冒号：中文用全角，英文用半角加空格。
    static var colon: String { L10n.isChinese ? "：" : ": " }

    /// 手动「报告问题」的正文。
    static func feedbackBody(note: String, documentName: String?) -> String {
        var body = "# \(t("Problem report"))\n\n"
        body += "- \(t("Time"))\(Self.colon)\(stampFormatter.string(from: Date()))\n"
        body += "- \(t("Version"))\(Self.colon)\(CrashEnvironment.appVersion)"
            + "（\(CrashEnvironment.architecture)）\n"
        body += "- \(t("System"))\(Self.colon)\(CrashEnvironment.systemDescription)\n"
        if let documentName { body += "- \(t("Document"))\(Self.colon)\(documentName)\n" }
        body += "\n## \(t("What I was doing"))\n\n"
        body += note.isEmpty ? t("_(add a sentence here)_") : note
        body += "\n"
        return body
    }

    // MARK: 轨迹解读

    /// 轨迹里最后一条 `windows N`——退出时开着几扇窗。
    static func windowCount(in breadcrumbs: [String]) -> Int? {
        for line in breadcrumbs.reversed() {
            guard let range = line.range(of: "windows ") else { continue }
            return Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// 轨迹里最后一条 `doc X`——崩溃时手上是哪一篇（只有文件名，没有内容）。
    static func documentName(in breadcrumbs: [String]) -> String? {
        for line in breadcrumbs.reversed() {
            guard let range = line.range(of: "doc ") else { continue }
            let name = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// 轨迹里最后一条 `launch toss X`——**写下这份现场的进程**的版本。
    ///
    /// 收报告的是下一次启动的进程，`CrashEnvironment.appVersion` 是它的版本；
    /// 中间隔着一次升级的话（#252：0.15.30 被结束、0.15.31 收的报告），
    /// 报告头写着 0.15.31、排查的人却在找 0.15.31 的毛病——版本必须取
    /// 死去那一位自报的。
    static func launchedVersion(in breadcrumbs: [String]) -> String? {
        for line in breadcrumbs.reversed() {
            guard let range = line.range(of: "launch toss ") else { continue }
            let version = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return version.isEmpty ? nil : version
        }
        return nil
    }

    // MARK: 小工具

    static func newID(now: Date = Date()) -> String {
        let stamp = idFormatter.string(from: now)
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(stamp)-\(suffix)"
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// 给面板与 issue 标题用的时间。语言跟着界面走，格式跟着地区惯例。
    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")
        formatter.dateFormat = L10n.isChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return formatter
    }()
}
