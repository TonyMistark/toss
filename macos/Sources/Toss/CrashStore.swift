import AppKit
import Combine
import Foundation

/// 崩溃报告的账房：收现场、列清单、标「看过了」、交给人。
///
/// 目录本身就是账本——一份报告一个 `.tosscrash` 文件，旁边的 `.seen` 是
/// 「这份已经给读者看过了」。不另存索引：报告可能被读者在访达里直接删掉、
/// 拷走、发给别人，索引一旦比文件多活一天就会对不上。
///
/// 除了 `harvest()`（启动时把上次的半成品整理成报告），这里**不联网**、
/// 不上传、不读文档内容。要不要发出去由读者按那个按钮决定。
@MainActor
final class CrashStore: ObservableObject {
    let directory: URL
    /// 全部报告，新的在前。
    @Published private(set) var reports: [CrashReport] = []
    /// 每次变动 +1。面板与状态栏靠它刷新（`@Published` 的数组比较也不便宜）。
    @Published private(set) var revision = 0
    private var seen: Set<String> = []
    private let fileManager: FileManager
    private let clock: () -> Date
    /// 最多留几份。超过就删最旧的——报告是给人看的，不是日志归档。
    let maxReports: Int
    /// 超过这么久的自动清掉。
    let maxAge: TimeInterval
    /// 正式版的账本里不显示开发版留下的报告（`version: dev`）。
    ///
    /// 开发时被 `kill -9`、被重编译挤掉都是常态，那些「没有正常退出」不是
    /// 读者的事（#147）。开发版自己跑起来时这个开关是关的——它要看得见自己的现场。
    let hidesDevelopmentReports: Bool

    init(
        directory: URL? = nil,
        clock: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        maxReports: Int = 20,
        maxAge: TimeInterval = 90 * 86_400,
        hidesDevelopmentReports: Bool = !CrashEnvironment.isDevelopmentBuild
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.clock = clock
        self.fileManager = fileManager
        self.maxReports = maxReports
        self.maxAge = maxAge
        self.hidesDevelopmentReports = hidesDevelopmentReports
    }

    static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("toss", isDirectory: true)
            .appendingPathComponent(directoryName(forVersion: CrashEnvironment.appVersion), isDirectory: true)
    }

    /// 开发版与正式版各记一本账：`crashes` 是读者的，`crashes-dev` 是我们的。
    ///
    /// 混在一起的代价是实打实的：#147 那份 `vdev` 的「没有正常退出」在读者面板里
    /// 长得就像应用崩了，还一路提交成了 issue。开发时被杀是日常，不该让读者收尸。
    static func directoryName(forVersion version: String) -> String {
        version.isEmpty || version == "dev" ? "crashes-dev" : "crashes"
    }

    // MARK: - 读

    /// 还没给读者看过的那些（新的在前）。
    var pending: [CrashReport] { reports.filter { !seen.contains($0.id) } }

    var hasPending: Bool { !pending.isEmpty }

    func text(of report: CrashReport) -> String { report.markdown }

    func report(id: String) -> CrashReport? { reports.first { $0.id == id } }

    // MARK: - 收

    /// 把上一次留下的现场整理成报告。**必须在装信号处理器之前调用**——
    /// 装的时候会清空轨迹文件，那是给这一次用的。
    ///
    /// 半成品（`.inflight-*.raw`）可能是：崩溃当场写下的、或者只写了个头
    /// （强退、断电，进程来不及写）。后一种同样值得说一声：读者看到的是
    /// 「窗口突然没了」，原因不明比知道「没抓到现场」更难受。
    /// - Parameter isLiveOwner: 这份现场是不是「另一位 toss 正在写」。默认问系统，
    ///   测试换成一个闭包就能把「并排跑」与「上次死掉」两种情形都演出来。
    func harvest(isLiveOwner: (URL) -> Bool = CrashStore.ownerIsRunning) {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: []
        )) ?? []
        // 另一份 toss 正在用这个目录时，它的现场文件不是「上次的遗物」——
        // `swift run` 出来的开发版没有 bundle id，可以和正式版并排跑；
        // 把活着的那个收成「没正常退出」是纯误报。
        let inflight = files.filter {
            $0.lastPathComponent.hasPrefix(".inflight-") && !isLiveOwner($0)
        }
        guard !inflight.isEmpty else {
            reload()
            prune()
            return
        }

        for url in inflight {
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? clock()
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let raw = CrashRaw.parse(text)
            let breadcrumbs = Self.breadcrumbs(in: directory)
            // 崩溃时刻优先信现场里写的那行（处理器当场记的）；现场文件是启动时
            // 预建的，创建时间其实是**启动**时间——拿它当崩溃时刻能差出半小时（#181）。
            let capturedAt = raw.unixSeconds.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            } ?? createdAt
            let report = Self.report(from: raw, breadcrumbs: breadcrumbs, capturedAt: capturedAt)
            write(report)
            try? fileManager.removeItem(at: url)
        }
        reload()
        prune()
    }

    /// 读目录，重建清单。
    func reload() {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: []
        )) ?? []
        var loaded: [CrashReport] = []
        var seenIDs: Set<String> = []
        for url in files {
            let name = url.lastPathComponent
            if name.hasSuffix(".seen") {
                seenIDs.insert(String(name.dropLast(".seen".count)))
                continue
            }
            guard name.hasSuffix(".tosscrash"),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let report = CrashReport.parse(text, fileURL: url)
            else { continue }
            // 开发版的现场不进读者的账本（#147）。文件留着，只是不列出来。
            if hidesDevelopmentReports, report.appVersion == "dev" { continue }
            loaded.append(report)
        }
        reports = loaded.sorted { $0.capturedAt > $1.capturedAt }
        seen = seenIDs
        revision += 1
    }

    // MARK: - 看过了 / 删掉

    func markSeen(_ id: String) {
        markAllSeen([id])
    }

    func markAllSeen(_ ids: [String]? = nil) {
        let targets = ids ?? reports.map(\.id)
        for id in targets where !seen.contains(id) {
            let url = directory.appendingPathComponent("\(id).seen")
            try? Data().write(to: url)
            seen.insert(id)
        }
        revision += 1
    }

    /// 删一份报告（连同「看过了」的标记）。
    func remove(_ id: String) {
        for suffix in [".tosscrash", ".seen"] {
            try? fileManager.removeItem(at: directory.appendingPathComponent(id + suffix))
        }
        reload()
    }

    func clearAll() {
        for report in reports {
            try? fileManager.removeItem(
                at: directory.appendingPathComponent("\(report.id).tosscrash")
            )
            try? fileManager.removeItem(at: directory.appendingPathComponent("\(report.id).seen"))
        }
        reload()
    }

    /// 只留最近的若干份、且不过期。删文件不动内存清单——调用方要么接着
    /// `reload()`，要么在 `harvest()` 的尾巴上被统一刷新。
    func prune() {
        let cutoff = clock().addingTimeInterval(-maxAge)
        var kept = 0
        for report in reports {
            let tooOld = report.capturedAt < cutoff
            let tooMany = kept >= maxReports
            if tooOld || tooMany {
                try? fileManager.removeItem(
                    at: directory.appendingPathComponent("\(report.id).tosscrash")
                )
                try? fileManager.removeItem(
                    at: directory.appendingPathComponent("\(report.id).seen")
                )
            } else {
                kept += 1
            }
        }
        if kept != reports.count { reload() }
    }

    // MARK: - 手动反馈

    /// 读者点「报告问题」：留一份带环境的说明，好发给人看。
    ///
    /// 这是**主动**生成的报告，不需要下次启动再问一遍，所以直接标成看过了。
    @discardableResult
    func recordFeedback(note: String, documentName: String?) -> CrashReport {
        let report = CrashReport.make(
            kind: .feedback,
            documentName: documentName,
            body: CrashReport.feedbackBody(note: note, documentName: documentName)
        )
        write(report)
        markSeen(report.id)
        reload()
        return report
    }

    // MARK: - 交出去

    /// 预填好的 GitHub 新建 issue 页面。打不开浏览器也算正常（没网、被策略拦），
    /// 调用方退回「复制报告」即可。
    func issueURL(for report: CrashReport) -> URL? {
        GitHubIssue.newIssueURL(title: report.suggestedIssueTitle, body: report.markdown)
    }

    @discardableResult
    func openIssue(for report: CrashReport) -> Bool {
        guard let url = issueURL(for: report) else { return false }
        // 浏览器没打开（没网、被策略拦）就不算「已经说过」——面板留着，
        // 读者还能复制报告、自己找地方贴。
        guard NSWorkspace.shared.open(url) else { return false }
        markSeen(report.id)
        return true
    }

    func copyToPasteboard(_ report: CrashReport) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.markdown, forType: .string)
    }

    func reveal(_ report: CrashReport) {
        if let url = report.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    // MARK: - 写

    private func write(_ report: CrashReport) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(report.id).tosscrash")
        try? report.markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 现场 → 报告

    /// 把原始材料补成人能读的一份：版本、系统、轨迹都在这一步补齐。
    static func report(
        from raw: CrashRaw,
        breadcrumbs: [String],
        capturedAt: Date
    ) -> CrashReport {
        // 有帧才算「抓到了现场」；只有头的是强退/断电。
        let kind: CrashReport.Kind = raw.frames.isEmpty ? .terminated : raw.kind
        // 版本取死去那一位自报的（轨迹 launch 行）。收报告的进程可能已经
        // 升过级——报成自己的版本会让人排查一个不存在的版本（#252）。
        let version = CrashReport.launchedVersion(in: breadcrumbs) ?? CrashEnvironment.appVersion
        return CrashReport.make(
            capturedAt: capturedAt,
            kind: kind,
            signal: kind == .terminated ? nil : raw.signal,
            appVersion: version,
            windowCount: CrashReport.windowCount(in: breadcrumbs),
            documentName: CrashReport.documentName(in: breadcrumbs),
            body: CrashReport.crashBody(
                raw: raw, breadcrumbs: breadcrumbs, capturedAt: capturedAt,
                kind: kind, appVersion: version
            )
        )
    }

    // MARK: - 现场属于谁

    /// 现场文件名是 `.inflight-<pid>-<启动时刻>.raw`，写它的进程号就在里面。
    nonisolated static func ownerPID(of url: URL) -> pid_t? {
        let parts = url.lastPathComponent.split(separator: "-")
        guard parts.count >= 3, parts[0] == ".inflight" else { return nil }
        return pid_t(parts[1])
    }

    /// 写这份现场的进程还活着，而且跑的就是同一个可执行文件？那它是一次
    /// **正在进行中**的运行，不是上次留下的残骸。
    ///
    /// 光看进程号不够：号码会被别的程序复用，那样会把真正的崩溃报告压掉。
    nonisolated static func ownerIsRunning(_ url: URL) -> Bool {
        guard let pid = ownerPID(of: url) else { return false }
        return isLiveSibling(
            pid: pid,
            runningPath: executablePath(of: pid),
            ownPath: executablePath(of: getpid())
        )
    }

    /// 判据本身是纯函数：进程号活着、不是自己、而且跑的是同一个可执行文件。
    ///
    /// 最后一个条件不能省：进程号会被别的程序复用，只比号的话，
    /// 一份真正的崩溃报告会被当成「人家还在跑」扔掉。
    nonisolated static func isLiveSibling(pid: pid_t, runningPath: String?, ownPath: String?) -> Bool {
        guard pid > 0, pid != getpid(), let runningPath, let ownPath else { return false }
        return PathKey.canonical(URL(fileURLWithPath: runningPath))
            == PathKey.canonical(URL(fileURLWithPath: ownPath))
    }

    /// 进程正在跑的可执行文件。进程已经不在了就 nil。
    nonisolated private static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` 在 Swift 里不可见（宏里有 4*MAXPATHLEN）。
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return PathKey.canonical(URL(fileURLWithPath: String(cString: buffer)))
    }

    /// 读上一次留下的轨迹。文件读不到就空着——报告少一段，照样有用。
    static func breadcrumbs(in directory: URL, limit: Int = 40) -> [String] {
        let url = directory.appendingPathComponent("breadcrumbs.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(limit))
    }
}
