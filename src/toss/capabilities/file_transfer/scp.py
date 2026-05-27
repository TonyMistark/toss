"""SCP/SSH 底层操作（异步版本）。

所有函数返回字符串结果（成功）或抛出异常（失败）。
由上层（CLI / MCP tool handler）负责捕获异常并格式化错误。
"""

import asyncio
import os
import tarfile
import tempfile
import time
from pathlib import Path

from toss.config import ServerConfig


def _expand(path: str) -> str:
    return os.path.expanduser(path)


def _remote_target(s: ServerConfig, path: str) -> str:
    addr = f"{s.user}@{s.host}" if s.user else s.host
    return f"{addr}:{path}"


def _ssh_dest(s: ServerConfig) -> str:
    return f"{s.user}@{s.host}" if s.user else s.host


def _scp_port_args(s: ServerConfig) -> list[str]:
    return ["-P", str(s.port)] if s.port and s.port != 22 else []


def _ssh_port_args(s: ServerConfig) -> list[str]:
    return ["-p", str(s.port)] if s.port and s.port != 22 else []


# ── 目录打包 ────────────────────────────────────────────────────────

def _pack_directory_sync(dirpath: str, tmpdir: str) -> str:
    dirname = os.path.basename(os.path.normpath(dirpath))
    tarpath = os.path.join(tmpdir, f"{dirname}.tar.gz")
    with tarfile.open(tarpath, "w:gz") as tar:
        tar.add(dirpath, arcname=dirname)
    return tarpath


async def _resolve_files(files: list[str]) -> tuple[list[str], list[str]]:
    """处理文件列表：目录异步打包为 tar.gz。

    返回 (send_list, temp_files)，temp_files 需要发送后清理。
    """
    send_list: list[str] = []
    temp_files: list[str] = []
    tmpdir: str | None = None

    for f in files:
        f = os.path.normpath(f)
        if not os.path.exists(f):
            raise FileNotFoundError(f"文件不存在：{f}")

        if os.path.isdir(f):
            if tmpdir is None:
                tmpdir = tempfile.mkdtemp(prefix="toss_")
            tarpath = await asyncio.to_thread(_pack_directory_sync, f, tmpdir)
            send_list.append(tarpath)
            temp_files.append(tarpath)
        else:
            send_list.append(f)

    return send_list, temp_files


async def _run(cmd: list[str]) -> tuple[int, str, str]:
    """运行子进程，返回 (returncode, stdout, stderr)。"""
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout_b, stderr_b = await proc.communicate()
    return proc.returncode, stdout_b.decode(), stderr_b.decode()


# ── 文件发送 ────────────────────────────────────────────────────────

async def send_files(s: ServerConfig, files: list[str], target_dir: str) -> str:
    """发送本地文件到服务器。目录自动打包为 tar.gz。返回成功摘要。"""
    target_dir = _expand(target_dir)
    send_list, temp_files = await _resolve_files(files)
    started = time.time()

    try:
        cmd = ["scp", *_scp_port_args(s), *send_list, _remote_target(s, target_dir + "/")]
        rc, _, stderr = await _run(cmd)
        elapsed = time.time() - started

        if rc != 0:
            err = stderr.strip() or "scp 退出码非零"
            raise RuntimeError(
                f"{err}\n提示：检查 SSH 密钥是否已添加到目标服务器（ssh-copy-id {_ssh_dest(s)}）"
            )

        names = "、".join(
            Path(f).name + (" (目录已打包)" if f in temp_files else "")
            for f in send_list
        )
        return f"✓ 已发送到 {_remote_target(s, target_dir)} ({elapsed:.1f}s)\n  {names}"

    finally:
        for tf in temp_files:
            try:
                os.remove(tf)
            except OSError:
                pass
        if temp_files:
            try:
                os.rmdir(os.path.dirname(temp_files[0]))
            except OSError:
                pass


# ── 文件拉取 ────────────────────────────────────────────────────────

async def pull_file(s: ServerConfig, remote_file: str, output_dir: str, target_dir: str) -> str:
    """从服务器拉取文件到本地。返回成功摘要。"""
    target_dir = _expand(target_dir)
    output_dir = _expand(output_dir)
    os.makedirs(output_dir, exist_ok=True)

    started = time.time()
    cmd = [
        "scp",
        *_scp_port_args(s),
        _remote_target(s, target_dir + "/" + remote_file),
        output_dir + "/",
    ]
    rc, _, stderr = await _run(cmd)
    elapsed = time.time() - started

    if rc != 0:
        err = stderr.strip() or "scp 退出码非零"
        raise RuntimeError(
            f"{err}\n提示：用 toss ls {_resolve_server_name(s)} 确认文件名是否正确"
        )

    local_path = os.path.join(output_dir, remote_file)
    return f"✓ {_remote_target(s, target_dir + '/' + remote_file)} → {local_path} ({elapsed:.1f}s)"


# ── 远程列表 ────────────────────────────────────────────────────────

async def list_remote(s: ServerConfig, target_dir: str) -> str:
    """列出远程服务器目标目录的文件。"""
    target_dir = _expand(target_dir)
    cmd = ["ssh", *_ssh_port_args(s), _ssh_dest(s), "ls", "-lh", target_dir]
    rc, stdout, stderr = await _run(cmd)

    if rc != 0:
        err = stderr.strip() or "ssh 退出码非零"
        raise RuntimeError(
            f"{err}\n提示：确认服务器地址和 SSH 密钥配置（ssh {_ssh_dest(s)}）"
        )

    output = stdout.strip()
    if not output:
        return f"{_ssh_dest(s)}:{target_dir}/ 是空的"
    return f"{_ssh_dest(s)}:{target_dir}/\n{output}"


# ── 服务器列表 ──────────────────────────────────────────────────────

def format_server_list(servers: dict[str, ServerConfig], target_dir: str) -> str:
    """格式化已配置的服务器列表。"""
    if not servers:
        return (
            "没有配置任何服务器。\n"
            f"请编辑 ~/.toss/config.json，在 file_transfer.servers 下添加服务器。"
        )

    lines = []
    for name, s in servers.items():
        port_str = f":{s.port}" if s.port and s.port != 22 else ""
        user_str = s.user if s.user else "(默认用户)"
        lines.append(f"  {name:16s} → {user_str}@{s.host}{port_str}")

    count = len(lines)
    header = "已配置的服务器：\n" if count == 1 else f"已配置 {count} 台服务器：\n"
    footer = f"\n文件收发目录：{target_dir}"
    return header + "\n".join(lines) + footer


# ── 内部工具 ────────────────────────────────────────────────────────

def _resolve_server_name(s: ServerConfig) -> str:
    """从 ServerConfig 反推显示名（用于错误提示）。"""
    return s.host
