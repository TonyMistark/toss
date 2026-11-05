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

    /// 目录不存在时先建出来，保证默认的 `~/.toss` 在首次使用时也能直接浏览。
    static func ensureDirectory(_ directory: String) -> String {
        "mkdir -p \(remoteQuote(directory.trimmed))"
    }

    static func join(_ directory: String, _ name: String) -> String {
        let base = directory.trimmed
        if base.hasSuffix("/") {
            return base + name
        }
        return base + "/" + name
    }

    /// 源端命令：在源目录里打包/读取。`./` 前缀避免以 `-` 开头的名字被当成选项。
    static func source(directory: String, entries: [ThrowEntry], mode: ThrowMode) -> String {
        let names = entries.map { quote("./\($0.name)") }.joined(separator: " ")
        let cd = "cd \(remoteQuote(directory.trimmed))"
        switch mode {
        case .direct:
            return "\(cd) && exec cat \(names)"
        case .archive:
            return "\(cd) && exec tar -czf - \(names)"
        }
    }

    /// 目标端命令：把 stdin 解到临时目录（归档），或写成一个文件（直传）。
    static func destination(root: String, entries: [ThrowEntry], mode: ThrowMode) -> String {
        let dir = remoteQuote(root.trimmed)
        switch mode {
        case .direct:
            let name = entries.first?.name ?? "payload"
            return "mkdir -p \(dir) && exec cat > \(remoteQuote(join(root, name)))"
        case .archive:
            return "mkdir -p \(dir) && exec tar -xzf - -C \(dir)"
        }
    }

    /// 把临时目录里的顶层条目搬进目标目录；同名时加 `-2`、`-3` 后缀。
    /// 空目录也清理掉，失败时由调用方 `rm -rf` 兜底。
    static func moveScript(temp: String, target: String) -> String {
        """
        set -e
        tmp=\(remoteQuote(temp.trimmed))
        dest=\(remoteQuote(target.trimmed))
        mkdir -p "$dest"
        cd "$tmp"
        for f in * .[!.]*; do
          [ -e "$f" ] || continue
          if [ ! -e "$dest/$f" ]; then
            mv "$f" "$dest/$f"
            continue
          fi
          stem="$f"
          ext=""
          case "$f" in
            *.*)
              stem="${f%.*}"
              ext=".${f##*.}"
              ;;
          esac
          n=2
          while [ -e "$dest/$stem-$n$ext" ]; do n=$((n+1)); done
          mv "$f" "$dest/$stem-$n$ext"
        done
        cd /
        rm -rf "$tmp"
        """
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
}
