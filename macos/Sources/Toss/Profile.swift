import AppKit
import Foundation
import SwiftUI

// MARK: - 个人信息

/// 「我是谁」——昵称与头像。
///
/// 只存本地：昵称进 `UserDefaults`，头像是一张 512 px 的 PNG，落在
/// `Application Support/toss/profile/avatar.png`。不联网、不上传、不写进任何
/// 文档——设置页上那句话不是装饰。
///
/// 目录与 defaults 都可注入：测试用临时目录与自己的 suite，绝不碰真数据。
@MainActor
final class ProfileStore: ObservableObject {
    private enum Key {
        static let nickname = "toss.profile.nickname"
    }

    /// 头像存下来时的边长。再大对一枚工具栏图标没有意义，只会把磁盘写胖。
    static let avatarSide: CGFloat = 512

    private let directory: URL
    private let defaults: UserDefaults

    /// 昵称。空字符串 = 没设，界面退回占位文案。
    @Published var nickname: String {
        didSet {
            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed, forKey: Key.nickname)
        }
    }

    /// 头像。没有就是 nil——视图负责画默认头像，这里不造假图。
    @Published private(set) var avatar: NSImage?

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? Self.defaultDirectory
        self.defaults = defaults
        nickname = defaults.string(forKey: Key.nickname) ?? ""
        avatar = Self.loadAvatar(in: self.directory)
    }

    static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("toss", isDirectory: true)
            .appendingPathComponent("profile", isDirectory: true)
    }

    var avatarURL: URL {
        directory.appendingPathComponent("avatar.png")
    }

    // MARK: 展示用

    var hasNickname: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 默认头像中间那个字：昵称的第一个字（emoji、汉字都算一个字）。
    var initial: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return String(first).uppercased()
    }

    /// 「我」在界面上叫什么。没设昵称时用一句中性的自称，不写「未命名」。
    var displayName: String {
        hasNickname ? nickname.trimmingCharacters(in: .whitespacesAndNewlines) : t("Me")
    }

    // MARK: 改

    /// 存一张新头像。写不下去就返回 false，界面据此提示，不改内存里的旧值。
    @discardableResult
    func setAvatar(_ image: NSImage) -> Bool {
        guard let data = Self.png(from: image, side: Self.avatarSide) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: avatarURL, options: .atomic)
        } catch {
            return false
        }
        avatar = NSImage(data: data)
        return true
    }

    /// 从磁盘上的图片文件读一张进来（设置页的「选择图片…」走这里）。
    @discardableResult
    func setAvatar(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        return setAvatar(image)
    }

    /// 回到默认头像。
    func clearAvatar() {
        try? FileManager.default.removeItem(at: avatarURL)
        avatar = nil
    }

    // MARK: 落盘

    private static func loadAvatar(in directory: URL) -> NSImage? {
        let url = directory.appendingPathComponent("avatar.png")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// 缩到 `side` 见方以内再转 PNG：原图可能是 4000 px 的照片，
    /// 存进去只为了画一枚 20 pt 的圆。
    ///
    /// 走 `NSBitmapImageRep` 而不是 `lockFocus`：后者按屏幕的 scale 出图，
    /// Retina 上 512 pt 会落成 1024 px——「存小一点」就白做了。
    private static func png(from image: NSImage, side: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, side / max(size.width, size.height))
        let target = NSSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let tiff = rep.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - 头像

/// 一枚圆形头像：有图就填图，没有就画昵称首字，再没有就放一个人像。
///
/// 工具栏、设置侧栏、个人信息页用的是同一个视图——三处显示同一个人，
/// 才不会出现「侧栏里是我，工具栏里是系统人像」这种分裂。
struct ProfileAvatar: View {
    var image: NSImage?
    var initial: String = ""
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(background)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else if !initial.isEmpty {
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.52))
                    .foregroundStyle(.white.opacity(0.95))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    /// 没有照片时的底色：一点点斜向的层次，比一块纯色更像「一个头像」。
    private var background: LinearGradient {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.95),
                Color.accentColor.opacity(0.62),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
