"""file_transfer capability — MCP 工具 & CLI 子命令注册"""

import argparse
import os
from typing import Optional

from toss.config import load_config, create_default_config
from toss.capabilities.file_transfer.scp import (
    send_files,
    pull_file,
    list_remote,
    format_server_list,
)


# ── 通用 handler（CLI & MCP 共用）───────────────────────────────────

def _get_ft_config():
    """加载配置并返回 file_transfer 部分。异常统一抛给上层。"""
    cfg = load_config()
    return cfg.file_transfer


def _resolve_server(ft, server_name: str):
    """根据名称查找服务器，找不到时抛出 ValueError。"""
    s = ft.get_server(server_name)
    if s is None:
        available = "、".join(ft.server_names()) if ft.server_names() else "(无)"
        raise ValueError(f"未知服务器 {server_name!r}，已配置：{available}")
    return s


# ── CLI handlers ────────────────────────────────────────────────────

def _cli_send(args):
    ft = _get_ft_config()
    s = _resolve_server(ft, args.server)
    return send_files(s, args.files, ft.target_dir)


def _cli_pull(args):
    ft = _get_ft_config()
    s = _resolve_server(ft, args.server)
    output = args.output or "."
    return pull_file(s, args.file, output, ft.target_dir)


def _cli_ls(args):
    ft = _get_ft_config()
    s = _resolve_server(ft, args.server)
    return list_remote(s, ft.target_dir)


def _cli_list(args):
    ft = _get_ft_config()
    return format_server_list(ft.servers, ft.target_dir)


def _cli_init(args):
    path = create_default_config(force=args.force)
    return f"✓ 配置文件已创建：{path}\n请编辑此文件，添加你的服务器信息。"


# ── MCP tool handlers ───────────────────────────────────────────────

def _mcp_send(server: str, files: list[str]) -> str:
    ft = _get_ft_config()
    s = _resolve_server(ft, server)

    # 展开通配符（shell 没展开时兜底）
    import glob as _glob
    expanded = []
    for f in files:
        matches = _glob.glob(f)
        expanded.extend(matches if matches else [f])

    return send_files(s, expanded, ft.target_dir)


def _mcp_pull(server: str, file: str, output: str = ".") -> str:
    ft = _get_ft_config()
    s = _resolve_server(ft, server)
    return pull_file(s, file, output, ft.target_dir)


def _mcp_ls(server: str) -> str:
    ft = _get_ft_config()
    s = _resolve_server(ft, server)
    return list_remote(s, ft.target_dir)


def _mcp_list_servers() -> str:
    ft = _get_ft_config()
    return format_server_list(ft.servers, ft.target_dir)


def _mcp_init_config() -> str:
    path = create_default_config()
    return (
        f"✓ 配置文件已创建：{path}\n"
        f"请编辑此文件，添加你的服务器信息。\n"
        f"格式示例：\n"
        f"  file_transfer:\n"
        f"    target_dir: ~/toss\n"
        f"    servers:\n"
        f"      prod:\n"
        f"        host: 10.0.0.50\n"
        f"        user: root\n"
    )


# ── 注册入口 ────────────────────────────────────────────────────────

def register_mcp(app) -> None:
    """在 MCP Server 上注册工具"""

    @app.tool()
    async def send(server: str, files: list[str]) -> str:
        """发送本地文件到服务器的收发目录。如果是目录会自动打包为 tar.gz 后发送。server: 服务器名称, files: 要发送的文件路径列表（可包含目录）。返回传输结果摘要。"""
        try:
            return _mcp_send(server, files)
        except Exception as e:
            return f"✗ 发送失败：{e}"

    @app.tool()
    async def pull(server: str, file: str, output: str = ".") -> str:
        """从服务器的收发目录拉取文件到本地。server: 服务器名称, file: 远程文件名, output: 本地保存目录(可选,默认当前目录)。返回传输结果摘要。"""
        try:
            return _mcp_pull(server, file, output)
        except Exception as e:
            return f"✗ 拉取失败：{e}"

    @app.tool()
    async def ls(server: str) -> str:
        """列出服务器收发目录下的文件。server: 服务器名称。返回文件列表及大小。"""
        try:
            return _mcp_ls(server)
        except Exception as e:
            return f"✗ 查看失败：{e}"

    @app.tool()
    async def list_servers() -> str:
        """列出所有已配置的服务器及其连接信息。"""
        try:
            return _mcp_list_servers()
        except Exception as e:
            return f"✗ 读取配置失败：{e}"

    @app.tool()
    async def init_config() -> str:
        """创建 ~/.toss/config.yaml 配置模板（如已存在则跳过）。首次使用 toss 前需调用。"""
        try:
            return _mcp_init_config()
        except Exception as e:
            return f"✗ 创建配置失败：{e}"


def register_cli(subparsers) -> None:
    """注册 CLI 子命令到 argparse subparsers"""

    # toss send
    p = subparsers.add_parser("send", help="发送文件到服务器（目录自动打包）")
    p.add_argument("files", nargs="+", help="本地文件路径")
    p.add_argument("server", help="服务器名称")
    p.set_defaults(handler=_cli_send)

    # toss pull
    p = subparsers.add_parser("pull", help="从服务器拉取文件")
    p.add_argument("server", help="服务器名称")
    p.add_argument("file", help="远程文件名")
    p.add_argument("output", nargs="?", default=".", help="本地保存目录（默认当前目录）")
    p.set_defaults(handler=_cli_pull)

    # toss ls
    p = subparsers.add_parser("ls", help="列出服务器收发目录的文件")
    p.add_argument("server", help="服务器名称")
    p.set_defaults(handler=_cli_ls)

    # toss list
    p = subparsers.add_parser("list", help="列出已配置的服务器")
    p.set_defaults(handler=_cli_list)

    # toss init
    p = subparsers.add_parser("init", help="创建配置文件模板")
    p.add_argument("--force", action="store_true", help="覆盖已有配置")
    p.set_defaults(handler=_cli_init)

