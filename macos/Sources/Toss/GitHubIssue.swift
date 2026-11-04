import Foundation

/// 「去 GitHub 上开一个 issue」这件事，只剩拼一个链接。
///
/// 不代读者提交：那需要一个写权限的 token，得存在这台机器上，还得解释它
/// 能做什么——为了一次点击的方便，把一把能改仓库的钥匙放在别人电脑里，不值。
/// 预填好的新建页面是同样的两步（看一眼、按提交），却没有那把钥匙。
enum GitHubIssue {
    static let repository = "TonyMistark/toss"

    /// 整条 URL 的长度上限。浏览器与 GitHub 都能吃得下八千上下，留一点余量。
    /// 按**编码后**的长度算：一个汉字编码成九个字节，按字符数算会超得离谱。
    static let lengthLimit = 7000

    static func newIssueURL(
        title: String,
        body: String,
        repository: String = repository,
        limit: Int = lengthLimit
    ) -> URL? {
        let cleanTitle = clipped(title, to: 140)
        guard let full = compose(title: cleanTitle, body: body, repository: repository) else {
            return nil
        }
        if full.absoluteString.count <= limit { return full }

        // 太长：对半砍，直到装得下。报告的结构（头部、调用栈开头）都在前面，
        // 砍掉的多半是轨迹的尾巴——那正是最不重要的部分。
        let marker = t("\n\n… (truncated — copy the full report from toss)")
        var cut = body.count / 2
        while cut > 80 {
            guard let candidate = compose(
                title: cleanTitle, body: String(body.prefix(cut)) + marker, repository: repository
            ) else { return full }
            if candidate.absoluteString.count <= limit { return candidate }
            cut /= 2
        }
        return full
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static func compose(title: String, body: String, repository: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}
