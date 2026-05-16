"""CLI 模式入口。

通过 argparse 解析子命令，分发到各 capability 的 handler。
支持快捷写法：toss <文件...> <服务器> 等同于 toss send <文件...> <服务器>
"""

import argparse
import os
import sys


# 已知的子命令列表（由各 capability 注册）
KNOWN_COMMANDS = {"send", "pull", "ls", "list", "init"}


def _is_likely_filepath(s: str) -> bool:
    """判断一个字符串是否像文件路径（而不是子命令或服务器名）"""
    return os.path.exists(s) or "/" in s or "." in s or s.endswith((".pdf", ".txt", ".gz", ".zip", ".tar", ".csv", ".json", ".yaml", ".yml", ".log", ".sql", ".py", ".js", ".ts", ".go", ".rs"))


def run_cli():
    """CLI 主入口。解析参数并执行对应 handler。"""

    # 检查是否是快捷写法：toss <看起来像文件的东西...> <服务器>
    args = sys.argv[1:]
    if args and args[0] not in KNOWN_COMMANDS and _is_likely_filepath(args[0]):
        # 快捷 send：把最后一个参数当服务器名，前面的当文件
        files = args[:-1]
        server = args[-1]
        from toss.capabilities.file_transfer import _cli_send

        class NS:
            pass
        ns = NS()
        ns.files = files
        ns.server = server
        try:
            result = _cli_send(ns)
            print(result)
        except Exception as e:
            print(f"✗ 发送失败：{e}", file=sys.stderr)
            sys.exit(1)
        return

    # 标准子命令模式
    parser = argparse.ArgumentParser(
        prog="toss",
        description="个人工具集 — 支持 CLI 和 MCP 两种模式",
    )
    subparsers = parser.add_subparsers(dest="command", help="可用命令")

    # 加载各 capability 的 CLI 子命令
    from toss.capabilities.file_transfer import register_cli
    register_cli(subparsers)

    parsed = parser.parse_args()

    if not hasattr(parsed, "handler") or parsed.handler is None:
        parser.print_help()
        sys.exit(0)

    try:
        result = parsed.handler(parsed)
        print(result)
    except Exception as e:
        print(f"✗ 错误：{e}", file=sys.stderr)
        sys.exit(1)
