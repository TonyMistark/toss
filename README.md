# toss

[![CI](https://github.com/TonyMistark/toss/actions/workflows/ci.yml/badge.svg)](https://github.com/TonyMistark/toss/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/tests-14%20passed-brightgreen)](#)

个人工具集 MCP 服务。把常用运维操作封装成 MCP 工具，既可以在终端里敲命令用，也可以注册到 Claude Code 让 AI 帮你执行。

## 安装

### 全局安装（推荐）

安装后 `toss` 在任意终端都可直接使用：

```bash
git clone <repo-url> && cd toss
uv tool install .
```

### 开发安装

在项目目录内运行，不注册全局命令：

```bash
git clone <repo-url> && cd toss
uv sync
```

## 更新

拉到新代码后重新安装即可升级：

```bash
cd /path/to/toss && git pull
uv tool install . --reinstall
```

## 卸载

```bash
uv tool uninstall toss-mcp
```

## 注册到 Claude Code

在 `~/.claude/claude_desktop_config.json` 或项目的 `.claude/mcp.json` 中添加：

```json
{
  "mcpServers": {
    "toss": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/toss", "toss"]
    }
  }
}
```

注册后重启 Claude Code，toss 的工具就会出现在 AI 可调用的工具列表中。

## Mac App

原生 SwiftUI 版，和 CLI 共用同一份 `~/.toss/config.json`，命令行功能保持不变。

```bash
./scripts/build_app.sh        # 生成 build/Toss.app
open build/Toss.app           # 运行
```

把 `build/Toss.app` 拖进「应用程序」即可长期使用。

功能：

- 服务器配置增删改（名称、主机、用户、端口、多个收发目录）
- 全局收发目录设置
- 选中机器只列出它配置的文件夹，点开某个文件夹才加载文件列表（每个文件夹可单独刷新）
- 把文件或目录拖到目标机器上即开始投递；目标机器有多个文件夹时会展开对应数量的篮筐，拖进哪个篮筐就落到哪个文件夹
- 文件夹自动打包为 tar.gz；本机也作为来源，把 `~/.toss`（或设置里指定的目录）里的文件拖到服务器即上传
- 拖拽时自动排除来源机器，不会出现自己拖给自己
- 执行日志页：工具栏打开后按时间列出目录加载、拖拽投递、每条 SSH 命令、传输阶段与错误，可搜索、复制和清空

App 直接调用系统 `scp` / `ssh`，前置条件与 CLI 相同（SSH 密钥免密登录）。GUI 进程没有终端，因此使用 `BatchMode=yes` 快速失败，并用 `StrictHostKeyChecking=accept-new` 自动接受首次连接的主机指纹。

### 发布与更新

版本号以 `macos/Info.plist` 的 `CFBundleShortVersionString` 为准，Release tag 必须是 `v<版本号>`
（例如 `v0.1.0`）。安装包命名为 `dist/toss-<版本号>.dmg`。

```bash
# 本地打包
TOSS_VERSION=0.1.0 ./scripts/build_app.sh
VERSION=0.1.0 ./scripts/package_dmg.sh

# 发布前必须隔离冒烟：挂载 dmg，用独立 HOME 启动，校验轨迹与崩溃目录
VERSION=0.1.0 ./scripts/smoke_test.sh

# 发布：推 tag 后 GitHub Actions 自动测试、构建、创建 GitHub Release
git tag v0.1.0
git push origin v0.1.0

# 同一份 dmg 也会上传到 Gitee，供 GitHub 下载失败时回退
# 一次性配置：gh secret set GITEE_TOKEN -R TonyMistark/toss
```

Gitee 镜像由 `.github/workflows/gitee-sync.yml` 自动同步，Release 失败不会反过来挡住 GitHub 发布。
幂等补跑：

```bash
# 本机兜底令牌（一次性）
mkdir -p ~/.config/toss
echo '<Gitee token>' > ~/.config/toss/gitee-token
chmod 600 ~/.config/toss/gitee-token

# 补单个版本 / 全量补齐历史版本
./sync-gitee-release.sh v0.1.0
./sync-gitee-all.sh
```

App 内置更新器会同时查 GitHub 与 Gitee（`TonyMistark/toss` / `Micestark/toss`），
优先 GitHub；GitHub 检查或下载失败时自动换到 Gitee。安装前一定会弹出确认。

## 配置

配置文件 `~/.toss/config.json`，首次使用前运行 `toss init` 创建模板：

```json
{
  "file_transfer": {
    "target_dir": "~/.toss",
    "servers": {
      "prod": {
        "host": "10.0.0.50",
        "user": "root"
      },
      "nas": {
        "host": "nas.local",
        "user": "ice",
        "port": 2222,
        "target_dir": "~/custom_path"
      }
    }
  }
}
```

`target_dir` 支持三级覆盖（优先级从高到低）：

| 级别 | 位置 | 默认值 | 说明 |
|------|------|--------|------|
| 全局 | `file_transfer.target_dir` | `"~/.toss"` | 所有服务器的默认收发目录 |
| 服务器 | `file_transfer.servers.<name>.target_dir` | 继承全局 | 单个服务器覆盖全局目录 |
| 调用时 | `send` 工具的 `target_dir` 参数 | 继承服务器/全局 | 仅 `send` 支持，优先级最高 |

不设置服务器级 `target_dir` 时自动继承全局值。示例中 `prod` 使用全局的 `~/.toss`，`nas` 使用独立的 `~/custom_path`。

macOS 应用还支持服务器级的 `target_dirs` 数组，用于给一台机器配置多个收发目录；命令行工具读取时会使用数组中的第一个目录。

## 使用方式

### CLI 模式

```bash
toss send report.pdf prod               # 扔文件到服务器
toss send a.txt b.txt nas               # 一次扔多个
toss pull prod data.csv                 # 从服务器拿文件
toss ls prod                            # 看服务器上有什么
toss list                               # 列出所有服务器
toss init                               # 创建配置模板
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
