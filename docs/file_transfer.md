# file_transfer — 服务器文件传输

在服务器之间收发文件。指定文件名和目标服务器，底层通过 SCP 传输。

## 配置

```json
{
  "file_transfer": {
    "target_dir": "~/toss",
    "servers": {
      "prod": {
        "host": "10.0.0.50",
        "user": "root"
      },
      "nas": {
        "host": "nas.home.lan",
        "user": "ice",
        "port": 2222
      }
    }
  }
}
```

所有文件统一收发到各服务器的 `target_dir` 目录下，不需要每次指定路径。

## 前置条件

1. 本机可通过 `ssh` / `scp` 免密登录目标服务器（密钥已配置）
2. 每个目标服务器上已创建对应的 `target_dir` 目录（默认 `~/toss/`）

## CLI 命令

### send — 发送文件到服务器

```bash
uv run toss send <文件...> <服务器>

uv run toss send report.pdf prod
uv run toss send a.txt b.txt c.txt nas
# 快捷写法（省略 send）：
uv run toss report.pdf prod
```

将本地文件复制到 `服务器:target_dir/` 下。

### pull — 从服务器拉取文件

```bash
uv run toss pull <服务器> <文件名> [本地路径]

uv run toss pull prod data.csv            # 拉到当前目录
uv run toss pull prod data.csv ./downloads/
```

将 `服务器:target_dir/文件名` 复制到本地。

### ls — 查看服务器上的文件

```bash
uv run toss ls <服务器>

uv run toss ls prod
```

列出服务器 `target_dir` 下的文件及大小。

### list — 列出已配置的服务器

```bash
uv run toss list
```

### init — 创建配置文件模板

```bash
uv run toss init
```

在 `~/.toss/config.json` 创建配置模板。

## MCP 工具

注册到 Claude Code 后，AI 可使用以下工具：

### send

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `server` | string | ✓ | 服务器名称 |
| `files` | string[] | ✓ | 本地文件路径列表 |

返回示例：

```
✓ 已发送到 root@10.0.0.50:~/toss/ (0.8s)
  report.pdf、data.csv
```

### pull

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `server` | string | ✓ | 服务器名称 |
| `file` | string | ✓ | 远程文件名（在 target_dir 下） |
| `output` | string | ✗ | 本地输出路径，默认当前目录 |

返回示例：

```
✓ root@nas.local:~/toss/data.csv → ./data.csv (0.3s)
```

### ls

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `server` | string | ✓ | 服务器名称 |

返回示例：

```
root@nas.local:~/toss/
total 2.1G
-rw-r--r--  1 ice  staff  2.1G  5 16 10:00 backup.tar.gz
-rw-r--r--  1 ice  staff  3.4K  5 15 09:30 nginx.conf
```

### list_servers

无参数。返回已配置的服务器列表。

### init_config

无参数。创建 `~/.toss/config.json` 配置模板。如果已存在则跳过。

## 错误处理

| 场景 | 返回 |
|------|------|
| 没找到配置文件 | `未找到配置，请先运行 toss init 或调用 init_config` |
| 服务器名不在配置中 | `未知服务器 "xxx"，已配置的服务器：prod, nas` |
| 本地文件不存在 | `文件不存在：/path/to/file` |
| SSH 连接失败 | 直接返回 scp/ssh 的错误输出 |
| 远程 target_dir 不存在 | 直接返回 scp 错误，用户需在服务器上 `mkdir` |
| pull 时远程文件不存在 | 直接返回 scp 错误输出 |
