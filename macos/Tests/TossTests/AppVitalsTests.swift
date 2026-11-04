import Foundation
import Testing

@testable import Toss

// MARK: - 版本号

/// 版本比较是更新的地基：比错了就会给一个装不上的「新版」，或者永远
/// 不提示。这张表来自真实踩过的几类 tag。
@Suite("版本号比较")
struct AppVersionTests {
    @Test("数字段逐位比，缺位补 0")
    func comparesCoreSegments() {
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        #expect(AppVersion("0.4")! == AppVersion("0.4.0")!)
        #expect(AppVersion("v0.4.1")! > AppVersion("0.4.0")!)
    }

    @Test("预发布版低于同号正式版")
    func prereleaseIsLower() {
        #expect(AppVersion("0.4.0-beta.2")! < AppVersion("0.4.0")!)
        #expect(AppVersion("0.4.0-beta.2")! < AppVersion("0.4.0-beta.10")!)
        #expect(AppVersion("0.4.0-beta")! < AppVersion("0.4.0-beta.1")!)
    }

    @Test("构建元数据不参与比较；解析不了就是 nil——宁可漏提示，不误报")
    func rejectsGarbage() {
        #expect(AppVersion("0.4.0+build.7")! == AppVersion("0.4.0")!)
        #expect(AppVersion("nightly") == nil)
        #expect(AppVersion("v") == nil)
    }
}

// MARK: - 先问后装

/// 更新的三条铁律：**问过才装**、**顺序不乱**、**拒绝就一个字节都不碰**。
@Suite("一键更新的流程", .serialized)
@MainActor
struct UpdateInstallerFlowTests {
    private let asset = UpdateAsset(
        url: URL(string: "https://example.invalid/app-1.2.3.dmg")!,
        name: "app-1.2.3.dmg",
        byteCount: 3_100_000
    )

    /// 步骤全换成记账替身：不碰真网络、不碰 /Applications、不重启。
    private func makeInstaller(order: @escaping (String) -> Void) -> UpdateInstaller {
        let installer = UpdateInstaller(steps: UpdateInstaller.Steps(
            download: { _, progress in
                order("download")
                progress(0.5)
                return URL(fileURLWithPath: "/tmp/app-1.2.3.dmg")
            },
            mount: { _ in
                order("mount")
                return URL(fileURLWithPath: "/Volumes/app/app.app")
            },
            install: { _, _, _ in
                order("install")
                return URL(fileURLWithPath: "/Applications/App.app")
            },
            relaunch: { _ in order("relaunch") },
            reveal: { _ in order("reveal") }
        ))
        return installer
    }

    @Test("问过才装：下载 → 确认 → 挂载 → 装配 → 重启")
    func asksBeforeInstalling() async {
        var order: [String] = []
        let installer = makeInstaller { order.append($0) }
        installer.stepsForTest(confirm: { _ in true })

        await installer.run(asset: asset, version: "1.2.3", releaseURL: URL(string: "https://example.invalid")!)

        #expect(order == ["download", "mount", "install", "relaunch"])
        #expect(installer.phase == .idle)
    }

    @Test("点「以后」：不挂载、不装配、不重启，dmg 留着")
    func laterLeavesEverythingUntouched() async {
        var order: [String] = []
        let installer = makeInstaller { order.append($0) }
        installer.stepsForTest(confirm: { _ in false })

        await installer.run(asset: asset, version: "1.2.3", releaseURL: URL(string: "https://example.invalid")!)

        #expect(order == ["download"])
        #expect(installer.phase == .idle)
        #expect(installer.downloadedDMG != nil, "dmg 留着——设置页的访达退路还要用它")
    }
}

// MARK: - 崩溃报告

/// 收现场的那一段：只有头 = 强退（`terminated`）；处理器写了 kind 就算崩溃，
/// 哪怕抓栈失败、帧为空。
@Suite("崩溃报告入账", .serialized)
@MainActor
struct CrashStoreHarvestTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("上一次留下的现场会被整理成报告")
    func harvestsInFlightFile() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 现场文件是启动时预建的，所以创建时间其实是**启动**时间——
        // 崩溃时刻必须信文件里那行 `t`（#181 的教训）。
        // 这里用一小时前的时刻：太旧的报告会被 `prune()` 当过期清掉。
        let crashTime = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let raw = """
        WTMDCRASH 1
        kind signal
        signal SIGSEGV
        t \(crashTime)
        frames
        0   App  0x0000000100001234 main + 12
        end

        """
        let inflight = directory.appendingPathComponent(".inflight-999999-\(crashTime).raw")
        try raw.write(to: inflight, atomically: true, encoding: .utf8)

        let store = CrashStore(directory: directory, hidesDevelopmentReports: false)
        store.harvest(isLiveOwner: { _ in false })

        #expect(store.reports.count == 1)
        #expect(store.reports.first?.kind == .signal)
        #expect(store.reports.first?.signal == "SIGSEGV")
        #expect(store.hasPending, "收上来的报告默认是「还没看过」")
        #expect(!FileManager.default.fileExists(atPath: inflight.path), "半成品收完就该删掉")
    }

    @Test("只有头没有帧：报成「没有正常退出」，不假装抓到了栈")
    func headerOnlyIsTerminated() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let inflight = directory.appendingPathComponent(".inflight-999998-1760000000.raw")
        try "WTMDCRASH 1\n".write(to: inflight, atomically: true, encoding: .utf8)

        let store = CrashStore(directory: directory, hidesDevelopmentReports: false)
        store.harvest(isLiveOwner: { _ in false })

        #expect(store.reports.first?.kind == .terminated)
    }

    @Test("写了信号但抓栈失败：仍算崩溃，不冒充「没有正常退出」")
    func signalWithoutFramesIsStillACrash() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 处理器跑到了，只是 `backtrace` 没抓到帧——这依然是真崩溃（#1）。
        let crashTime = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let raw = """
        WTMDCRASH 1
        kind signal
        signal SIGSEGV
        t \(crashTime)
        frames
        end

        """
        let inflight = directory.appendingPathComponent(".inflight-999997-\(crashTime).raw")
        try raw.write(to: inflight, atomically: true, encoding: .utf8)

        let store = CrashStore(directory: directory, hidesDevelopmentReports: false)
        store.harvest(isLiveOwner: { _ in false })

        #expect(store.reports.first?.kind == .signal)
        #expect(store.reports.first?.signal == "SIGSEGV")
    }

    @Test("另一个实例正在写的现场不算遗物——不能报成崩溃")
    func liveSiblingIsNotACrash() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let inflight = directory.appendingPathComponent(".inflight-\(getpid())-1760000000.raw")
        try "WTMDCRASH 1\n".write(to: inflight, atomically: true, encoding: .utf8)

        let store = CrashStore(directory: directory, hidesDevelopmentReports: false)
        store.harvest(isLiveOwner: { _ in true })

        #expect(store.reports.isEmpty)
    }
}
