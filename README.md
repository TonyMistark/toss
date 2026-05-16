# toss

个人工具集 MCP 服务。把常用运维操作封装成 MCP 工具，既可以在终端里敲命令用，也可以注册到 Claude Code 让 AI 帮你执行。

## 安装

```bash
pipx install toss-mcp
# 或
pip install toss-mcp
```

## 注册到 Claude Code

在 `~/.claude/claude_desktop_config.json` 或项目的 `.claude/mcp.json` 中添加：

```json
{
  "mcpServers": {
    "toss": {
      "command": "python",
      "args": ["-m", "toss"]
    }
  }
}
```

注册后重启 Claude Code，toss 的工具就会出现在 AI 可调用的工具列表中。

## 配置

配置文件 `~/.toss/config.yaml`，首次使用前运行 `toss init` 创建模板：

```yaml
# 文件传输
file_transfer:
  target_dir: ~/toss
  servers:
    prod:
      host: 10.0.0.50
      user: root
    nas:
      host: nas.local
      user: ice
      port: 2222

# 未来其他工具
# some_tool:
#   ...
```

## 使用方式

### CLI 模式

```bash
toss send report.pdf prod           # 扔文件到服务器
toss send a.txt b.txt nas           # 一次扔多个
toss pull prod data.csv             # 从服务器拿文件
toss ls prod                        # 看服务器上有什么
toss list                           # 列出所有服务器
toss init                           # 创建配置模板
```

### MCP 模式

在 Claude Code 里直接用自然语言：

```
把 report.pdf 发到 prod
从 nas 把 backup.tar.gz 拿下来
看看 prod 上有哪些文件
帮我初始化 toss 配置
```

## 工具列表

| 工具 | 说明 | 文档 |
|------|------|------|
| `send` / `pull` / `ls` / `list_servers` / `init_config` | 服务器文件传输 | [docs/file_transfer.md](docs/file_transfer.md) |

## 架构

toss 同时支持 CLI 和 MCP 两种运行时模式：

- 启动时有命令行参数 → CLI 模式
- 启动时无参数 → MCP 模式（stdio JSON-RPC）

能力模块放在 `capabilities/` 下，每个模块提供核心逻辑 + MCP 工具注册 + CLI 子命令注册。新增工具只需添加一个目录。
