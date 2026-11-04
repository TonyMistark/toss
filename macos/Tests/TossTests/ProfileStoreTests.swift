import AppKit
import Foundation
import ImageIO
import Testing
@testable import Toss

// MARK: - 个人信息

/// 昵称与头像只存本地：昵称进 `UserDefaults`，头像是一张 PNG。这里守的是
/// **存得住、读得回、删得掉**——都发生在注入的临时目录与临时 suite 里，
/// 绝不碰读者的真数据。
@Suite("个人信息")
@MainActor
struct ProfileStoreTests {
    /// 一次性的 defaults：跑完连域一起删掉，别在真实偏好里留痕。
    private func withStore(
        _ body: (ProfileStore, URL, UserDefaults) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-profile-\(UUID().uuidString)", isDirectory: true)
        let suite = "toss.profile.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try body(ProfileStore(directory: directory, defaults: defaults), directory, defaults)
    }

    @Test("昵称存进 defaults，换一个实例还读得回来")
    func nicknameRoundTrips() throws {
        try withStore { profile, _, defaults in
            profile.nickname = "张三"
            #expect(defaults.string(forKey: "toss.profile.nickname") == "张三")

            let reopened = ProfileStore(directory: profile.avatarURL.deletingLastPathComponent(), defaults: defaults)
            #expect(reopened.nickname == "张三")
            #expect(reopened.hasNickname)
        }
    }

    @Test("只打空格等于没设：存下去的是修剪过的值")
    func nicknameIsTrimmed() throws {
        try withStore { profile, _, defaults in
            profile.nickname = "   "
            #expect(!profile.hasNickname)
            #expect(defaults.string(forKey: "toss.profile.nickname") == "")
            // 没昵称时用一句中性自称（中文表里是「我」），不写「未命名」
            #expect(profile.displayName == t("Me"))
            #expect(!profile.displayName.isEmpty)
            #expect(profile.initial.isEmpty)
        }
    }

    @Test("默认头像中间那个字：昵称的第一个字，中英文与 emoji 都算一个字")
    func initialIsTheFirstGrapheme() throws {
        try withStore { profile, _, _ in
            profile.nickname = "张三"
            #expect(profile.initial == "张")

            profile.nickname = "ice"
            #expect(profile.initial == "I")

            profile.nickname = "🌰 栗子"
            #expect(profile.initial == "🌰")
        }
    }

    @Test("头像：存下去、读回来、删干净")
    func avatarRoundTrips() throws {
        try withStore { profile, directory, defaults in
            #expect(profile.avatar == nil)
            #expect(!FileManager.default.fileExists(atPath: profile.avatarURL.path))

            #expect(profile.setAvatar(sampleImage(width: 800, height: 600)))
            #expect(profile.avatar != nil)
            #expect(FileManager.default.fileExists(atPath: profile.avatarURL.path))

            // 换一个实例：图是从盘上读的，不是内存里剩下的
            let reopened = ProfileStore(directory: directory, defaults: defaults)
            #expect(reopened.avatar != nil)

            // 缩到 512 见方以内：原图 800×600 存进去不该还是 800 宽
            let stored = try #require(CGImageSourceSize(profile.avatarURL))
            #expect(max(stored.width, stored.height) <= 512)
            #expect(stored.width > stored.height)   // 比例没被拉成方的

            profile.clearAvatar()
            #expect(profile.avatar == nil)
            #expect(!FileManager.default.fileExists(atPath: profile.avatarURL.path))
        }
    }

    @Test("读不成图片的文件：返回 false，也不把已有头像弄丢")
    func badFileLeavesTheOldAvatar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toss-profile-\(UUID().uuidString)", isDirectory: true)
        let suite = "toss.profile.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let profile = ProfileStore(directory: directory, defaults: defaults)
        #expect(profile.setAvatar(sampleImage(width: 64, height: 64)))
        let before = profile.avatar

        let bogus = directory.appendingPathComponent("not-a-picture.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "这不是图片".write(to: bogus, atomically: true, encoding: .utf8)

        #expect(!profile.setAvatar(from: bogus))
        #expect(profile.avatar != nil)
        #expect(profile.avatar?.size == before?.size)
    }
}

// MARK: - 造一张图

/// 真画一张：`NSImage(size:)` 空壳没有 bitmap，转 PNG 会得到 nil。
private func sampleImage(width: CGFloat, height: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor.white.setFill()
    NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
    image.unlockFocus()
    return image
}

/// 直接问 ImageIO 这张 PNG 有多大——不经过我们自己的解码路径，免得自证。
private func CGImageSourceSize(_ url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}
