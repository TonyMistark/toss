import Foundation

/// 目标端执行的 shell 片段都从这里生成，方便守卫测试直接断言转义与命名规则。
enum ThrowCommand {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 远端 shell 的单引号会阻止 `~` 展开，所以把开头的 `~` 换成 `$HOME`。
    static func remoteQuote(_ path: String) -> String {
        let trimmed = path.trimmed
        if trimmed == "~" { return "\"$HOME\"" }
        if trimmed.hasPrefix("~/") {
            return "\"$HOME\"/" + quote(String(trimmed.dropFirst(2)))
        }
        return quote(trimmed)
    }

    /// 只看，不动：远端目录必须由用户自己建好，Toss 绝不 `mkdir`。
    static func probeDirectory(_ directory: String) -> String {
        "test -d \(remoteQuote(directory.trimmed))"
    }

    /// 只列名字（用于撞名检查），不读大小，比 `list` 轻。
    static func names(_ directory: String) -> String {
        """
        cd \(remoteQuote(directory.trimmed)) || exit 1
        for f in * .[!.]*; do
          [ -e "./$f" ] || continue
          printf '%s\n' "$f"
        done
        """
    }

    static func join(_ directory: String, _ name: String) -> String {
        let base = directory.trimmed
        if base.hasSuffix("/") {
            return base + name
        }
        return base + "/" + name
    }

    /// 源端命令：在源目录里打包/读取。`./` 前缀避免以 `-` 开头的名字被当成选项。
    /// `verbose` 只在需要按文件推进进度时打开：tar 会把每个条目写到 stderr。
    static func source(
        directory: String,
        entries: [ThrowEntry],
        mode: ThrowMode,
        verbose: Bool = false
    ) -> String {
        let names = entries.map { quote("./\($0.name)") }.joined(separator: " ")
        let cd = "cd \(remoteQuote(directory.trimmed))"
        switch mode {
        case .direct:
            return "\(cd) && exec cat \(names)"
        case .archive:
            return "\(cd) && exec tar -cz\(verbose ? "v" : "")f - \(names)"
        }
    }

    /// 归档里一共有多少个条目（目录也算一个），用作进度分母。
    static func countItems(directory: String, entries: [ThrowEntry]) -> String {
        let names = entries.map { remoteQuote("./\($0.name)") }.joined(separator: " ")
        return """
        cd \(remoteQuote(directory.trimmed)) || exit 1
        find \(names) | wc -l
        """
    }

    /// 目标端命令：直接进到目标目录里落盘，不建目录、不清理任何东西。
    /// 目标目录必须已经存在（由 `probeDirectory` 事先确认）。
    static func destination(root: String, name: String, mode: ThrowMode) -> String {
        let cd = "cd \(remoteQuote(root.trimmed))"
        switch mode {
        case .direct:
            return "\(cd) && exec cat > \(quote(name))"
        case .archive:
            return "\(cd) && exec tar -xzf -"
        }
    }

    /// 精确字节数：`wc -c` 逐个文件执行，避免多文件时的 total 行干扰。
    static func exactBytes(paths: [String]) -> String {
        let list = paths.map { remoteQuote($0.trimmed) }.joined(separator: " ")
        return "find \(list) -type f -exec wc -c {} \\; | awk '{print $1+0}' | awk '{s+=$1} END {print s+0}'"
    }

    static func list(directory: String) -> String {
        """
        cd \(remoteQuote(directory.trimmed)) || exit 1
        for f in * .[!.]*; do
          [ -e "./$f" ] || continue
          if [ -d "./$f" ]; then
            s=$(du -sk "./$f" 2>/dev/null | awk '{print $1}')
            printf 'd\t%s\t%s\n' "${s:-0}" "$f"
          else
            s=$(wc -c < "./$f" 2>/dev/null | tr -d ' ')
            printf 'f\t%s\t%s\n' "${s:-0}" "$f"
          fi
        done
        """
    }
}

/// `ThrowCommand.list` 的输出解析。抽成纯函数，方便测试脚本与解析保持一致。
enum ThrowListing {
    static func parse(_ output: String) -> [ThrowEntry] {
        var entries: [ThrowEntry] = []

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let isDirectory = parts[0] == "d"
            let size = Int64(parts[1]) ?? 0
            entries.append(ThrowEntry(
                name: String(parts[2]),
                isDirectory: isDirectory,
                byteSize: isDirectory ? size * 1024 : size
            ))
        }

        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `ThrowCommand.names` 的输出：一行一个名字。
    static func parseNames(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }
}
