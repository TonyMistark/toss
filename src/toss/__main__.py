"""toss 入口 — 自动判断 CLI / MCP 模式"""

import sys


def main():
    if len(sys.argv) > 1:
        # 有命令行参数 → CLI 模式
        from toss.cli import run_cli
        run_cli()
    else:
        # 无参数 → MCP 模式（stdio JSON-RPC）
        from toss.server import run_server
        run_server()


if __name__ == "__main__":
    main()
