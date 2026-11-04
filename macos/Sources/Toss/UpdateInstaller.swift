import AppKit
import Foundation
import SwiftUI

// MARK: - 一键更新

/// 点一下徽标 = 下载 → 问一句「安装并重启？」→ 挂载 → 装进 /Applications → 重启。
///
/// 三条铁律，全都有测试钉着：
/// 1. **旧版神圣**——新 app 先在目标目录里拼装、校验（bundle 版本 = 目标版本），
///    全部通过之后才许碰已装的旧版；中途任何一步失败，旧版一个字节都不动。
/// 2. **降级不硬来**——装不进去就退回 Finder（把 dmg 在访达里亮出来），
///    拖不拖、什么时候拖，用户自己定。
/// 3. **可注入**——下载、挂载、装配、重启都是步骤闭包，测试不碰真网络、
///    不碰真 `/Applications`、更不会真的重启。
///
/// 下载完成不等于现在就要装：装新版本得退出应用，这一步交给用户点头
/// （`confirm` 步骤，生产实现是「安装并重启 / 以后」的弹窗）。
@MainActor
final class UpdateInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// 0..<1，来自 Content-Length。
        case downloading(fraction: Double)
        case installing
        /// 装不上时的原因；界面上给一条「去 Finder」的退路。
        case failed(reason: String)

        var isWorking: Bool {
            switch self {
            case .downloading, .installing: return true
            case .idle, .failed: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// 下载落在哪、装到哪。生产环境是临时目录与 `/Applications`。
    struct Locations {
        var downloads: URL
        var applications: URL
        /// 装好之后以这个名字出现在 applications 里。
        var appName = "Toss.app"

        static let production = Locations(
            downloads: FileManager.default.temporaryDirectory,
            applications: URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
    }

    // MARK: - 可注入的步骤

    struct Steps {
        /// 下载到本地，途中用 0..<1 报进度；返回 dmg 文件路径。
        var download: @MainActor (_ from: URL, _ progress: @MainActor @escaping (Double) -> Void) async throws -> URL
        /// 挂载 dmg，返回卷里那个 `.app` 的路径。
        var mount: @MainActor (_ dmg: URL) async throws -> URL
        /// 把 `.app` 装进目标目录，装完返回落点。**实现必须保证：失败时旧版原地不动。**
        var install: @MainActor (_ app: URL, _ locations: Locations, _ expectedVersion: String) async throws -> URL
        /// 重启进新装的那份。
        var relaunch: @MainActor (_ installed: URL) async throws -> Void
        /// 降级：把 dmg 在访达里亮出来。
        var reveal: @MainActor (_ dmg: URL) -> Void
        /// 下载完成之后问一句「现在装吗」。装新版本要退出应用，退出这件事
        /// 得用户点头——跟别的 app 一样：下载完了弹「安装并重启 / 以后」。
        ///
        /// 默认放行只为测试好写：生产入口 `productionSteps()` 一定换成了真弹窗。
        var confirm: @MainActor (_ version: String) async -> Bool = { _ in true }
    }

    private var steps: Steps
    private let locations: Locations

    init(steps: Steps, locations: Locations = .production) {
        self.steps = steps
        self.locations = locations
    }

    /// 降级要用：最后一枚成功落地的 dmg。
    private(set) var downloadedDMG: URL?

    // MARK: - 测试通道

    /// 替换个别步骤，没给的保持原样。
    func stepsForTest(
        download: (@MainActor (URL, @MainActor @escaping (Double) -> Void) async throws -> URL)? = nil,
        mount: (@MainActor (URL) async throws -> URL)? = nil,
        install: (@MainActor (URL, Locations, String) async throws -> URL)? = nil,
        relaunch: (@MainActor (URL) async throws -> Void)? = nil,
        reveal: (@MainActor (URL) -> Void)? = nil,
        confirm: (@MainActor (String) async -> Bool)? = nil
    ) {
        if let download { steps.download = download }
        if let mount { steps.mount = mount }
        if let install { steps.install = install }
        if let relaunch { steps.relaunch = relaunch }
        if let reveal { steps.reveal = reveal }
        if let confirm { steps.confirm = confirm }
    }

    // MARK: - 流程

    /// 从徽标或设置页按下去的那一下。`version` 用来在装完之后核对落点。
    ///
    /// `fallbacks` 是同一版本在别的源上的 dmg：主源下载失败就换地方再拿，
    /// 换源比让用户重新点一次便宜得多（下载失败最常见的两个原因是
    /// `release-assets.githubusercontent.com` 被掐和链路中途断流）。
    func run(
        asset: UpdateAsset,
        version: String,
        releaseURL: URL,
        fallbacks: [UpdateAsset] = []
    ) async {
        guard !phase.isWorking else { return }

        do {
            phase = .downloading(fraction: 0)
            let dmg = try await downloadFirst([asset] + fallbacks) { [weak self] fraction in
                self?.phase = .downloading(fraction: fraction)
            }
            downloadedDMG = dmg

            // 下载完不等于想现在装：装新版本要退出应用，这一步得用户点头。
            // 跟别的 app 一样——「安装并重启 / 以后」。点「以后」就到此为止，
            // 应用继续跑，旧版一个字节没动。
            guard await steps.confirm(version) else {
                phase = .idle
                return
            }

            phase = .installing
            let app = try await steps.mount(dmg)
            let installed = try await steps.install(app, locations, version)
            try await steps.relaunch(installed)
            phase = .idle
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(reason: Failure.describe(error))
        }
    }

    /// 按顺序试每个源，第一个拿到的就是它。全都失败才把最后一个错误抛出去
    /// ——报错要报「最后一个」，那才是用户当下最可能撞到的那个。
    private func downloadFirst(
        _ assets: [UpdateAsset],
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {
        var lastError: Error = URLError(.unknown)
        for asset in assets {
            do {
                return try await steps.download(asset.url, progress)
            } catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
            }
        }
        throw lastError
    }

    /// 装不上时的退路：访达里亮出 dmg，用户自己拖。
    func revealFallback() {
        guard let dmg = downloadedDMG else { return }
        steps.reveal(dmg)
    }

    /// 测试替换降级动作用。
    func revealForTest(_ reveal: @MainActor @escaping (URL) -> Void) {
        steps.reveal = reveal
    }

    func reset() {
        phase = .idle
    }

    // MARK: - 失败的措辞

    enum Failure: Error {
        case noAppInVolume
        case copyFailed(underlying: Error)
        case verifyFailed(expected: String, found: String?)
        case swapFailed(underlying: Error)

        static func describe(_ error: Error) -> String {
            if let failure = error as? Failure {
                switch failure {
                case .noAppInVolume:
                    return t("No app found in the downloaded image.")
                case .copyFailed:
                    return t("Could not stage the new app.")
                case .verifyFailed:
                    return t("The downloaded app is not the promised version.")
                case .swapFailed:
                    return t("Could not replace the installed app.")
                }
            }
            return error.localizedDescription
        }
    }

    // MARK: - 默认步骤

    static func productionSteps() -> Steps {
        Steps(
            download: { url, progress in
                try await Self.download(url, progress: progress)
            },
            mount: { dmg in
                try await Self.mount(dmg)
            },
            install: { app, locations, version in
                try Self.install(app: app, into: locations, expectedVersion: version)
            },
            relaunch: { installed in
                try await Self.relaunch(into: installed)
            },
            reveal: { dmg in
                NSWorkspace.shared.activateFileViewerSelecting([dmg])
            },
            confirm: { version in
                await Self.askToInstall(version: version)
            }
        )
    }

    // MARK: - 确认弹窗

    /// 下载完成后的那句问话：「安装并重启」还是「以后」。
    ///
    /// 挂在当前窗口上做 sheet；没有窗口（后台启动、窗口都关了）就退化成
    /// 独立弹窗——不能因为找不到窗口就把安装悄悄做了。
    /// Return = 「安装并重启」（默认按钮），Esc = 「以后」。
    @MainActor
    static func askToInstall(version: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = t("Toss {} is ready to install", version)
        alert.informativeText = t("Toss will quit to install the new version, then reopen your windows.")
        alert.addButton(withTitle: t("Install and Restart"))
        alert.addButton(withTitle: t("Later"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApplication.shared.activate(ignoringOtherApps: true)

        // 有窗口就贴着窗口弹（sheet）；窗口上已经挂着别的东西（崩溃提示、
        // 设置面板的 sheet）时 beginSheetModal 会静默失败，那就走独立弹窗。
        let host = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        guard let host, host.attachedSheet == nil else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: host) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    // MARK: - 下载

    /// 下载带重试：一个 3.5 MB 的文件断在中途，重来一次往往就过去了；
    /// 三次都不过才认输（失败自有换源兜底）。每次从头下，进度从头报。
    nonisolated static func download(
        _ url: URL,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do {
                return try await downloadOnce(url, progress: progress)
            } catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    nonisolated private static func downloadOnce(
        _ url: URL,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-update-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)

        // 成块落盘：三 MB 的 dmg 逐字节写系统调用会把进度拖到不可看
        let chunkSize = 256 * 1024
        var chunk = Data()
        chunk.reserveCapacity(chunkSize)
        var received: Int64 = 0
        var lastReported = -1.0

        func flush() throws {
            guard !chunk.isEmpty else { return }
            received += Int64(chunk.count)
            try handle.write(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
            if total > 0 {
                let fraction = Double(received) / Double(total)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    Task { @MainActor in progress(fraction) }
                }
            }
        }

        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= chunkSize { try flush() }
            }
            try flush()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return target
    }

    // MARK: - 挂载

    nonisolated static func mount(_ dmg: URL) async throws -> URL {
        let point = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["attach", dmg.path, "-readonly", "-nobrowse", "-quiet", "-mountpoint", point.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: point)
            throw Failure.copyFailed(underlying: NSError(
                domain: "toss.updates", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "hdiutil attach failed"]
            ))
        }

        // 卷里找 `.app`：发行镜像只有一份，取第一个就是它
        guard let enumerator = FileManager.default.enumerator(at: point, includingPropertiesForKeys: nil),
              let app = enumerator.allObjects.first(where: {
                  ($0 as? URL)?.pathExtension == "app"
              }) as? URL else {
            detach(point)
            throw Failure.noAppInVolume
        }
        return app
    }

    nonisolated private static func detach(_ point: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["detach", point.path, "-quiet"]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - 装配

    /// 装配的每一步都在目标目录里「先拼好、验完再换」：
    /// 暂存 → 摘 quarantine → 核版本 → 旧版挪走 → 暂存改名上位。
    /// 任何一步抛错，`/Applications/toss.app` 还是原来的那一份。
    /// - Parameter retire: 旧版怎么退位（进废纸篓）；可注入，测试不真丢废纸篓。
    nonisolated static func install(
        app: URL,
        into locations: Locations,
        expectedVersion: String,
        retire: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws -> URL {
        let manager = FileManager.default
        let destination = locations.applications
            .appendingPathComponent(locations.appName, isDirectory: true)
        let staging = locations.applications
            .appendingPathComponent("Toss.app.update-\(UUID().uuidString)", isDirectory: true)

        do {
            try manager.copyItem(at: app, to: staging)
        } catch {
            throw Failure.copyFailed(underlying: error)
        }
        defer { try? manager.removeItem(at: staging) }

        stripQuarantine(staging)

        // 版本核对：下载来的东西不许和说好的不一样
        let found = bundleVersion(of: staging)
        guard found == expectedVersion else {
            throw Failure.verifyFailed(expected: expectedVersion, found: found)
        }

        // 旧版退位：进废纸篓，进不了就改名让路——两条路都不删数据
        if manager.fileExists(atPath: destination.path) {
            do {
                try retire(destination)
            } catch {
                let aside = locations.applications
                    .appendingPathComponent("Toss.app.old-\(UUID().uuidString)", isDirectory: true)
                do {
                    try manager.moveItem(at: destination, to: aside)
                } catch {
                    throw Failure.swapFailed(underlying: error)
                }
            }
        }
        do {
            try manager.moveItem(at: staging, to: destination)
        } catch {
            throw Failure.swapFailed(underlying: error)
        }
        return destination
    }

    /// 摘掉 `com.apple.quarantine`：不摘的话重启会被 Gatekeeper 拦死
    /// （macOS 15+ 右键打开那条路已经没了）。xattr 缺席或失败都不拦装配——
    /// 最坏结果是重启时被拦一次，用户手动放行就好。
    nonisolated static func stripQuarantine(_ app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-cr", app.path]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    /// bundle 里报的版本；没有 Info.plist 就是 nil。
    nonisolated static func bundleVersion(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 探测 quarantine 标记（测试用）。
    nonisolated static func hasQuarantine(_ path: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-p", "com.apple.quarantine", path.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - 重启

    /// 重启进新装的那份。
    ///
    /// **不能直接 `openApplication`**：新版已经躺在同一个路径上、bundle id 也一模一样，
    /// LaunchServices 只会把「正在退场的自己」激活一下——回调里拿到的是**自己的 pid**，
    /// 一个新进程都没起。用户看到的就是「装完退出，再也没打开」（#195 真机探针实证：
    /// `openApplication returned pid=<自己>`，日志里只有一条 launch）。
    ///
    /// 于是把「等我们退干净，再开新版」交给一个脱离本进程的 shell：它是我们的子进程，
    /// 我们不 wait，父进程退出后它被 launchd 收养，继续等、继续开。
    nonisolated static func relaunch(into installed: URL) async throws {
        do {
            try spawnRelauncher(
                waitingFor: ProcessInfo.processInfo.processIdentifier,
                opening: installed
            )
        } catch {
            // 派生子进程被拒（沙箱）时的退路：强制新实例，至少窗口能回来。
            // 代价是可能和还没退干净的自己短暂并存，比什么都没有强。
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            try await NSWorkspace.shared.openApplication(at: installed, configuration: configuration)
        }
        await MainActor.run { NSApp.terminate(nil) }
    }

    /// 交给 `/bin/sh` 的那段话：等 `pid` 消失（最多 15 秒）再开新版。
    ///
    /// `-n` 是保险：旧进程真要卡着不退（例如保存冲突弹窗挡住了退出），也强制起
    /// 一个新实例，别让用户对着一片空桌面。
    nonisolated static func relaunchScript(waitingFor pid: Int32, opening app: URL) -> String {
        "i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt 75 ]; do sleep 0.2; i=$((i+1)); done; "
            + "exec /usr/bin/open -n \(shellQuoted(app.path))"
    }

    /// 单引号包住路径：`~/Applications/…` 这类带空格的路径不会被拆成两个参数。
    /// 单引号自己用 `'\''` 转义（shell 里唯一稳妥的写法）。
    nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 派生那个「收尸重启」的子进程；不等它——它要活到我们退场之后。
    nonisolated static func spawnRelauncher(waitingFor pid: Int32, opening app: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", relaunchScript(waitingFor: pid, opening: app)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
    }
}
