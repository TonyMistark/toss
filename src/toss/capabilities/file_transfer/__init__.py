"""file_transfer capability — MCP 工具 & CLI 子命令注册"""

import asyncio
import glob as _glob
import os
from typing import Optional

from pydantic import BaseModel, Field

from toss.config import load_config, create_default_config
from toss.capabilities.file_transfer.scp import (
    send_files,
    pull_file,
    list_remote,
    format_server_list,
)


# ── Pydantic 输入模型 ────────────────────────────────────────────────

class SendInput(BaseModel):
    server: str = Field(..., description="服务器名称，如 'prod'、'nas'")
    files: list[str] = Field(..., description="要发送的本地文件路径列表（可包含目录）", min_length=1)
    target_dir: Optional[str] = Field(default=None, description="远程目标目录，不填则使用配置文件中的默认值")


class PullInput(BaseModel):
    server: str = Field(..., description="服务器名称，如 'prod'、'nas'")
    file: str = Field(..., description="远程文件路径，支持绝对路径（如 '/home/user/file.txt'）或相对于 target_dir 的文件名（如 'report.pdf'）")
    output: str = Field(default=".", description="本地保存目录，默认当前目录")


class LsInput(BaseModel):
    server: str = Field(..., description="服务器名称，如 'prod'、'nas'")


# ── 公共工具函数 ────────────────────────────────────────────────────

def _get_ft_config():
    cfg = load_config()
    return cfg.file_transfer


def _resolve_server(ft, server_name: str):
    s = ft.get_server(server_name)
    if s is None:
        available = "、".join(ft.server_names()) if ft.server_names() else "(无)"
        raise ValueError(
            f"未知服务器 {server_name!r}。已配置：{available}。"
            f"运行 toss list 查看所有服务器，或编辑 ~/.toss/config.json 添加新服务器。"
        )
    return s


def _expand_globs(files: list[str]) -> list[str]:
    expanded = []
    for f in files:
        matches = _glob.glob(f)
        expanded.extend(matches if matches else [f])
    return expanded


# ── 公共异步 core（CLI 和 MCP 共用）────────────────────────────────

async def _do_send(server: str, files: list[str], target_dir: Optional[str] = None) -> str:
    ft = _get_ft_config()
    s = _resolve_server(ft, server)
    # 优先级：命令行参数 > 服务器配置 > 全局配置
    dest = target_dir or s.target_dir or ft.target_dir
    return await send_files(s, _expand_globs(files), dest)


async def _do_pull(server: str, file: str, output: str = ".") -> str:
    ft = _get_ft_config()
    s = _resolve_server(ft, server)
    dest = s.target_dir or ft.target_dir
    return await pull_file(s, file, output, dest)


async def _do_ls(server: str) -> str:
    ft = _get_ft_config()
    s = _resolve_server(ft, server)
    dest = s.target_dir or ft.target_dir
    return await list_remote(s, dest)


def _do_list_servers() -> str:
    ft = _get_ft_config()
    return format_server_list(ft.servers, ft.target_dir)


def _do_init_config() -> str:
    path = create_default_config()
    return (
        f"✓ 配置文件已创建：{path}\n"
        f"请编辑此文件，在 file_transfer.servers 下添加服务器信息。示例：\n"
        f'{{\n'
        f'  "file_transfer": {{\n'
        f'    "target_dir": "~/toss",\n'
        f'    "servers": {{\n'
        f'      "prod": {{"host": "10.0.0.50", "user": "root"}}\n'
        f'    }}\n'
        f'  }}\n'
        f'}}'
    )


# ── MCP 工具注册 ────────────────────────────────────────────────────

def register_mcp(app) -> None:
    """在 MCP Server 上注册工具"""

    @app.tool(
        name="send",
        annotations={
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": False,
            "openWorldHint": True,
        },
    )
    async def send(params: SendInput) -> str:
        """发送本地文件到服务器的收发目录。目录会自动打包为 tar.gz 后发送。返回传输结果摘要。"""
        try:
            return await _do_send(params.server, params.files, params.target_dir)
        except Exception as e:
            return f"✗ 发送失败：{e}"

    @app.tool(
        name="pull",
        annotations={
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": True,
        },
    )
    async def pull(params: PullInput) -> str:
        """从服务器的收发目录拉取文件到本地。返回传输结果摘要。"""
        try:
            return await _do_pull(params.server, params.file, params.output)
        except Exception as e:
            return f"✗ 拉取失败：{e}"

    @app.tool(
        name="ls",
        annotations={
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": True,
        },
    )
    async def ls(params: LsInput) -> str:
        """列出服务器收发目录下的文件及大小。"""
        try:
            return await _do_ls(params.server)
        except Exception as e:
            return f"✗ 查看失败：{e}"

    @app.tool(
        name="list_servers",
        annotations={
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    )
    async def list_servers() -> str:
        """列出所有已配置的服务器名称及连接信息。"""
        try:
            return _do_list_servers()
        except Exception as e:
            return f"✗ 读取配置失败：{e}"

    @app.tool(
        name="init_config",
        annotations={
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    )
    async def init_config() -> str:
        """创建 ~/.toss/config.json 配置模板（已存在则跳过）。首次使用 toss 前调用。"""
        try:
            return _do_init_config()
        except Exception as e:
            return f"✗ 创建配置失败：{e}"


# ── CLI 子命令注册 ────────────────────────────────────────────────────

def register_cli(subparsers) -> None:
    """注册 CLI 子命令到 argparse subparsers"""

    # toss send
    p = subparsers.add_parser("send", help="发送文件到服务器（目录自动打包）")
    p.add_argument("files", nargs="+", help="本地文件路径")
    p.add_argument("server", help="服务器名称")
    p.add_argument("--dest", default=None, help="远程目标目录（默认使用配置文件中的值）")
    p.set_defaults(handler=lambda args: asyncio.run(_do_send(args.server, args.files, args.dest)))

    # toss pull
    p = subparsers.add_parser("pull", help="从服务器拉取文件")
    p.add_argument("server", help="服务器名称")
    p.add_argument("file", help="远程文件名")
    p.add_argument("output", nargs="?", default=".", help="本地保存目录（默认当前目录）")
    p.set_defaults(handler=lambda args: asyncio.run(_do_pull(args.server, args.file, args.output)))

    # toss ls
    p = subparsers.add_parser("ls", help="列出服务器收发目录的文件")
    p.add_argument("server", help="服务器名称")
    p.set_defaults(handler=lambda args: asyncio.run(_do_ls(args.server)))

    # toss list
    p = subparsers.add_parser("list", help="列出已配置的服务器")
    p.set_defaults(handler=lambda args: _do_list_servers())

    # toss init
    p = subparsers.add_parser("init", help="创建配置文件模板")
    p.add_argument("--force", action="store_true", help="覆盖已有配置")
    p.set_defaults(handler=lambda args: _do_init_config())


# ── 快捷 send（cli.py 中的 shortcut 路径调用）──────────────────────

class _NS:
    pass


def _cli_send(args) -> str:
    return asyncio.run(_do_send(args.server, args.files, getattr(args, "dest", None)))
