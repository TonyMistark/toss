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

    @Test("顶部机器栏包含本机与所有服务器，来源也在其中")
    func machinesIncludeEveryone() {
        #expect(
            ThrowTargets.machines(servers: [a, b])
                == [.local, .server(a), .server(b)]
        )
        #expect(ThrowTargets.machines(servers: []) == [.local])
    }

    @Test("按 id 找回拉弓松手的目标")
    func resolvesTargetByID() {
        #expect(ThrowTargets.target(id: "local", servers: [a]) == .local)
        #expect(ThrowTargets.target(id: "server:a", servers: [a]) == .server(a))
        #expect(ThrowTargets.target(id: "server:b", servers: [a, b]) == .server(b))
        #expect(ThrowTargets.target(id: "server:x", servers: [a]) == nil)
        #expect(ThrowTargets.target(id: "bogus", servers: [a]) == nil)
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

// MARK: - 执行日志

@Suite("执行日志缓冲")
struct LogBufferTests {
    private func makeEntry(_ message: String) -> LogEntry {
        LogEntry(date: Date(), level: .info, message: message)
    }

    @Test("超出上限时只保留最新的条目")
    func trimsOldestEntries() {
        var buffer = LogBuffer(limit: 3)
        for index in 1...5 {
            buffer.append(makeEntry("line \(index)"))
        }
        #expect(buffer.entries.count == 3)
        #expect(buffer.entries.map(\.message) == ["line 3", "line 4", "line 5"])
    }

    @Test("清空后可以重新记录")
    func clearsAndRestarts() {
        var buffer = LogBuffer(limit: 10)
        buffer.append(makeEntry("a"))
        buffer.removeAll()
        #expect(buffer.entries.isEmpty)

        buffer.append(makeEntry("b"))
        #expect(buffer.entries.map(\.message) == ["b"])
    }
}

// MARK: - 篮筐选择

@Suite("文件夹篮筐")
struct BasketChoiceTests {
    @Test("只接受这台机器配置的文件夹，前后空格会被忽略")
    func picksOnlyConfiguredFolders() {
        let folders = ["~/.toss", "/data/inbox"]
        #expect(BasketChoice.directory(" /data/inbox ", among: folders) == "/data/inbox")
        #expect(BasketChoice.directory("~/.toss", among: folders) == "~/.toss")
        #expect(BasketChoice.directory("/tmp", among: folders) == nil)
        #expect(BasketChoice.directory("", among: folders) == nil)
        #expect(BasketChoice.directory("   ", among: folders) == nil)
    }

    @Test("单目录任意落点都用它，多目录必须给出有效篮筐")
    func resolvesBasket() {
        #expect(BasketChoice.directory(for: nil, among: ["~/.toss"]) == "~/.toss")
        #expect(BasketChoice.directory(for: 1, among: ["a", "b"]) == "b")
        #expect(BasketChoice.directory(for: nil, among: ["a", "b"]) == nil)
        #expect(BasketChoice.directory(for: 5, among: ["a", "b"]) == nil)
    }

    @Test("拖拽落点换算到篮筐序号，卡片顶部与越界不误选")
    func mapsDropPositionToBasket() {
        #expect(DockBaskets.index(forY: 79, basketTop: 80, rowStride: 34, count: 3) == nil)
        #expect(DockBaskets.index(forY: 80, basketTop: 80, rowStride: 34, count: 3) == 0)
        #expect(DockBaskets.index(forY: 114, basketTop: 80, rowStride: 34, count: 3) == 1)
        #expect(DockBaskets.index(forY: 200, basketTop: 80, rowStride: 34, count: 3) == 2)
        #expect(DockBaskets.index(forY: 90, basketTop: 80, rowStride: 34, count: 1) == nil)
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

// MARK: - 远端落点

@Suite("远端落点")
struct RemotePlacementTests {
    private func file(_ name: String) -> ThrowEntry {
        ThrowEntry(name: name, isDirectory: false, byteSize: 1)
    }

    private func folder(_ name: String) -> ThrowEntry {
        ThrowEntry(name: name, isDirectory: true, byteSize: 1)
    }

    @Test("单文件撞名时换个名字，不覆盖")
    func directRenamesInsteadOfOverwriting() {
        #expect(
            RemotePlacement.plan(mode: .direct, entries: [file("report.pdf")], existing: [])
                == .direct(name: "report.pdf")
        )
        #expect(
            RemotePlacement.plan(mode: .direct, entries: [file("report.pdf")], existing: ["report.pdf"])
                == .direct(name: "report-2.pdf")
        )
    }

    @Test("文件夹或多选撞名直接拒绝，不改名也不删")
    func archiveBlocksOnCollision() {
        #expect(
            RemotePlacement.plan(mode: .archive, entries: [folder("photos")], existing: [])
                == .archive
        )
        #expect(
            RemotePlacement.plan(mode: .archive, entries: [folder("photos")], existing: ["photos"])
                == .blocked(name: "photos")
        )
        #expect(
            RemotePlacement.plan(mode: .archive, entries: [file("a.txt"), file("b.txt")], existing: ["b.txt"])
                == .blocked(name: "b.txt")
        )
    }
}

// MARK: - 归档进度

@Suite("归档进度")
struct TarProgressTests {
    @Test("按整行累计，未写完的半行留在 pending")
    func countsWholeLines() {
        var progress = TarProgress()
        progress.absorb("./photos/\n./photos/a.txt\n./pho")
        #expect(progress.processed == 2)
        #expect(progress.pending == "./pho")

        progress.absorb("tos/b.txt\n")
        #expect(progress.processed == 3)
        #expect(progress.pending == "")
    }

    @Test("进度封顶 98%，分母为 0 时不给百分比")
    func fraction() {
        var progress = TarProgress()
        #expect(progress.fraction(total: 0) == nil)
        #expect(progress.fraction(total: 10) == 0)

        progress.absorb(String(repeating: "x\n", count: 20))
        #expect(progress.fraction(total: 10) == 0.98)
    }

    @Test("剥掉 -v 的条目行，真正的报错保留")
    func stripsVerboseLines() {
        let gnu = """
        ./photos/
        ./photos/a.txt
        tar: ./photos/locked: Cannot stat: Permission denied
        tar: Exiting with failure status due to previous errors
        """
        #expect(
            TarProgress.errors(from: gnu)
                == "tar: ./photos/locked: Cannot stat: Permission denied\n"
                    + "tar: Exiting with failure status due to previous errors"
        )

        let bsdtar = """
        a ./photos
        a ./photos/a.txt
        tar: Error exit delayed from previous errors.
        """
        #expect(
            TarProgress.errors(from: bsdtar)
                == "tar: Error exit delayed from previous errors."
        )
    }
}

@Suite("投篮弧")
struct ShotArcTests {
    @Test("瞄准弧顺着方向拱到机器栏那一层，不贴具体篮筐")
    func previewStopsAtHorizon() {
        let mouse = CGPoint(x: 100, y: 600)
        let curve = ShotArc.preview(
            from: mouse,
            direction: CGPoint(x: 0, y: -1),
            horizon: 200,
            power: 80
        )
        #expect(curve.start == mouse)
        #expect(curve.end.y == 200)
        #expect(curve.end.x == 100)
        // 向上拱：控制点高于两端的中点。
        #expect(curve.control.y < (curve.start.y + curve.end.y) / 2)
    }

    @Test("拉得越远拱得越高")
    func liftsByPull() {
        let mouse = CGPoint(x: 100, y: 600)
        let short = ShotArc.preview(
            from: mouse, direction: CGPoint(x: 0, y: -1), horizon: 200, power: 80
        )
        let far = ShotArc.preview(
            from: mouse, direction: CGPoint(x: 0, y: -1), horizon: 200, power: 180
        )
        #expect(far.control.y < short.control.y)
    }

    @Test("弧顶高高越过两端，再落进篮筐")
    func apexFliesAboveBothEnds() {
        let mouse = CGPoint(x: 300, y: 620)
        let basket = CGPoint(x: 360, y: 200)
        let curve = ShotArc.shot(from: mouse, to: basket, power: 160)
        let heights = stride(from: 0.0, through: 1.0, by: 0.05)
            .map { ShotArc.point(curve, t: CGFloat($0)).y }
        #expect(heights.min()! < min(mouse.y, basket.y))
        // 左边起点一定低于弧顶，落点之前也确实在下降。
        #expect(ShotArc.point(curve, t: 0.55).y < ShotArc.point(curve, t: 0.85).y)
    }

    @Test("出手弧从松开的位置飞向篮筐")
    func shotEndsAtBasket() {
        let mouse = CGPoint(x: 120, y: 640)
        let basket = CGPoint(x: 360, y: 230)
        let curve = ShotArc.shot(from: mouse, to: basket, power: 100)
        #expect(ShotArc.point(curve, t: 0) == curve.start)
        #expect(ShotArc.point(curve, t: 1) == curve.end)
        #expect(curve.start == mouse)
        #expect(curve.end == basket)
        // 控制点抬到两点连线之上，弧线才会拱起来。
        #expect(curve.control.y < (mouse.y + basket.y) / 2)
    }
}

// MARK: - 拉弓瞄准

@Suite("拉弓瞄准")
struct ShotAimTests {
    private let machine = MachineAim(
        targetID: "server:b",
        cardFrame: CGRect(x: 200, y: 150, width: 220, height: 130),
        baskets: [
            BasketAim(anchor: CGPoint(x: 310, y: 190),
                      rect: CGRect(x: 208, y: 177, width: 204, height: 26)),
            BasketAim(anchor: CGPoint(x: 310, y: 220),
                      rect: CGRect(x: 208, y: 207, width: 204, height: 26)),
        ]
    )

    @Test("鼠标在下面、射线穿过篮筐就算投中")
    func hitsBasket() {
        let aim = ShotAim.aim(
            from: CGPoint(x: 310, y: 500),
            through: CGPoint(x: 310, y: 400),
            power: 120,
            among: [machine]
        )
        #expect(aim?.hit == true)
    }

    @Test("同一台机器命中整列时，射线指到哪个高度就选哪个文件夹")
    func selectsFolderByCrossingHeight() {
        let mouse = CGPoint(x: 500, y: 600)
        // 抬得陡：交点落在卡片上方，选最上面的文件夹。
        let steep = ShotAim.folderIndex(from: mouse,
                                        direction: CGPoint(x: -0.3, y: -0.954),
                                        machine: machine, power: 120)
        #expect(steep == 0)
        // 压得平：交点落到卡片下方，选最下面的文件夹。
        let flat = ShotAim.folderIndex(from: mouse,
                                       direction: CGPoint(x: -0.9, y: -0.436),
                                       machine: machine, power: 120)
        #expect(flat == 1)
    }

    @Test("射线几乎竖直时退回力度分档，越界夹回范围")
    func fallsBackToPowerBands() {
        let vertical = CGPoint(x: 0, y: -1)
        #expect(ShotAim.folderIndex(from: CGPoint(x: 310, y: 500),
                                    direction: vertical,
                                    machine: machine, power: 20) == 1)
        #expect(ShotAim.folderIndex(from: CGPoint(x: 310, y: 500),
                                    direction: vertical,
                                    machine: machine, power: 400) == 0)
        #expect(ShotAim.bandIndex(power: 400, count: 1) == 0)
    }

    @Test("射线擦不到篮筐时给最近的筐，但算没投中")
    func missesButStillAims() {
        let aim = ShotAim.aim(
            from: CGPoint(x: 100, y: 500),
            through: CGPoint(x: 300, y: 400),
            power: 120,
            among: [machine]
        )
        #expect(aim?.hit == false)
        #expect(aim?.basket == 1)
    }

    @Test("拉得太短或还没有目标时不投篮")
    func needsPullAndTargets() {
        #expect(ShotAim.aim(from: CGPoint(x: 310, y: 500),
                           through: CGPoint(x: 310, y: 490),
                           power: 10,
                           among: [machine]) == nil)
        #expect(ShotAim.aim(from: CGPoint(x: 310, y: 500),
                           through: CGPoint(x: 310, y: 400),
                           power: 120,
                           among: []) == nil)
    }

    @Test("射线与矩形求交：外面给距离，里面给 0，擦不到给 nil")
    func intersectsRects() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(ShotAim.rayDistance(from: CGPoint(x: 50, y: 200),
                                    direction: CGPoint(x: 0, y: -1),
                                    rect: rect) == 150)
        #expect(ShotAim.rayDistance(from: CGPoint(x: 50, y: 25),
                                    direction: CGPoint(x: 0, y: -1),
                                    rect: rect) == 0)
        #expect(ShotAim.rayDistance(from: CGPoint(x: 200, y: 200),
                                    direction: CGPoint(x: 0, y: -1),
                                    rect: rect) == nil)
        #expect(ShotAim.rayDistance(from: CGPoint(x: 50, y: 200),
                                    direction: CGPoint(x: 0, y: 1),
                                    rect: rect) == nil)
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

    @Test("远端只做检查，不建目录")
    func probeOnlyChecks() {
        #expect(ThrowCommand.probeDirectory("~/.toss") == "test -d \"$HOME\"/'.toss'")
        #expect(ThrowCommand.probeDirectory("/srv/data") == "test -d '/srv/data'")
    }

    @Test("源端文件带 ./ 前缀，-rf 之类的名字不会被当成选项")
    func sourcePrefixesDotSlash() {
        let entry = ThrowEntry(name: "-rf", isDirectory: false, byteSize: 1)
        #expect(
            ThrowCommand.source(directory: "/tmp/a b", entries: [entry], mode: .direct)
                == "cd '/tmp/a b' && exec cat './-rf'"
        )
        #expect(
            ThrowCommand.source(directory: "/tmp", entries: [entry], mode: .archive, verbose: true)
                == "cd '/tmp' && exec tar -czvf - './-rf'"
        )
        #expect(
            ThrowCommand.source(directory: "/tmp", entries: [entry], mode: .archive)
                == "cd '/tmp' && exec tar -czf - './-rf'"
        )
    }

    @Test("目标端直接落进既有目录，不建目录、不清理")
    func destinationWritesIntoExistingFolder() {
        #expect(
            ThrowCommand.destination(root: "/data/inbox", name: "report.pdf", mode: .direct)
                == "cd '/data/inbox' && exec cat > 'report.pdf'"
        )
        #expect(
            ThrowCommand.destination(root: "/data/inbox", name: "photos", mode: .archive)
                == "cd '/data/inbox' && exec tar -xzf -"
        )
    }

    @Test("归档源端带 -v 输出文件名，条目计数脚本只读")
    func archiveSourceIsVerbose() {
        let entry = ThrowEntry(name: "photos", isDirectory: true, byteSize: 10)
        #expect(
            ThrowCommand.source(directory: "/data", entries: [entry], mode: .archive, verbose: true)
                == "cd '/data' && exec tar -czvf - './photos'"
        )
        #expect(
            ThrowCommand.countItems(directory: "/data", entries: [entry])
                .contains("find './photos' | wc -l")
        )
    }

    @Test("所有远端命令都不创建目录、不删除任何东西")
    func remoteScriptsNeverCreateOrDelete() {
        let entry = ThrowEntry(name: "a.txt", isDirectory: false, byteSize: 1)
        let scripts = [
            ThrowCommand.probeDirectory("/data"),
            ThrowCommand.names("/data"),
            ThrowCommand.countItems(directory: "/data", entries: [entry]),
            ThrowCommand.list(directory: "/data"),
            ThrowCommand.exactBytes(paths: ["/data/a.txt"]),
            ThrowCommand.source(directory: "/data", entries: [entry], mode: .archive),
            ThrowCommand.destination(root: "/data", name: "a.txt", mode: .archive),
        ]
        for script in scripts {
            #expect(!script.contains("mkdir"))
            #expect(!script.contains("rm -"))
            #expect(!script.contains("mv "))
        }
    }

    @Test("只列名字的脚本输出能逐行解析")
    func namesScriptParses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-names-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "a".write(to: root.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("photos", isDirectory: true),
            withIntermediateDirectories: true
        )

        let names = Set(ThrowListing.parseNames(try runShell(ThrowCommand.names(root.path))))
        #expect(names == ["report.txt", ".env", "photos"])
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
