import Foundation

/// 「是不是同一个文件」的唯一判据。
///
/// 同一份文件可以被拼成 `/var/…` 与 `/private/var/…`：目录枚举返回的是解析过
/// 符号链接的路径，而从面板、会话、拖拽载荷来的可能没解析。URL 相等是字面比较，
/// 两种拼法会被当成两件不同的东西——v0.5 的 `allParts`、v0.6 的内存覆盖、
/// v0.7 的树高亮各踩过一次，所以判据只留一份，所有比较都从这里走。
enum PathKey {
    static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isSame(_ a: URL, _ b: URL) -> Bool {
        canonical(a) == canonical(b)
    }

    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        canonical(url).hasPrefix(canonical(root) + "/")
    }

    static func isDescendantOrSelf(_ url: URL, of root: URL) -> Bool {
        canonical(url) == canonical(root) || isDescendant(url, of: root)
    }
}
