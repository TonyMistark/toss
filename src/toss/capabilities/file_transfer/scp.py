"""SCP/SSH 底层操作。

所有函数返回字符串结果（成功）或抛出异常（失败）。
由上层（CLI / MCP tool handler）负责捕获异常并格式化错误。
"""

import os
import subprocess
import time
from pathlib import Path
from typing import Optional

from toss.config import ServerConfig


def _expand(path: str) -> str:
    return os.path.expanduser(path)


def _remote_target(s: ServerConfig, path: str) -> str:
    """scp 用的远程地址，如 user@host:/path/"""
    addr = f"{s.user}@{s.host}" if s.user else s.host
    return f"{addr}:{path}"


def _ssh_dest(s: ServerConfig) -> str:
    """ssh 用的登录地址"""
    return f"{s.user}@{s.host}" if s.user else s.host


# ── 文件发送 ────────────────────────────────────────────────────────

def send_files(s: ServerConfig, files: list[str], target_dir: str) -> str:
    """发送本地文件到服务器。返回成功摘要。"""
    target_dir = _expand(target_dir)

    # 校验本地文件存在
    missing = [f for f in files if not os.path.exists(f)]
    if missing:
        raise FileNotFoundError(f"文件不存在：{', '.join(missing)}")

    started = time.time()

    args = []
    if s.port and s.port != 22:
        args.extend(["-P", str(s.port)])
    args.extend(files)
    args.append(_remote_target(s, target_dir + "/"))

    proc = subprocess.run(
        ["scp", *args],
        capture_output=True, text=True,
    )
    elapsed = time.time() - started

    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "scp 失败")

    names = "、".join(f.name if hasattr(f, 'name') else f for f in [Path(x) for x in files])
    return f"✓ 已发送到 {_remote_target(s, target_dir)} ({elapsed:.1f}s)\n  {names}"


# ── 文件拉取 ────────────────────────────────────────────────────────

def pull_file(s: ServerConfig, remote_file: str, output_dir: str, target_dir: str) -> str:
    """从服务器拉取文件到本地。返回成功摘要。"""
    target_dir = _expand(target_dir)
    output_dir = _expand(output_dir)

    # 确保本地输出目录存在
    os.makedirs(output_dir, exist_ok=True)

    started = time.time()

    args = []
    if s.port and s.port != 22:
        args.extend(["-P", str(s.port)])
    args.append(_remote_target(s, target_dir + "/" + remote_file))
    args.append(output_dir + "/")

    proc = subprocess.run(
        ["scp", *args],
        capture_output=True, text=True,
    )
    elapsed = time.time() - started

    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "scp 失败")

    local_path = os.path.join(output_dir, remote_file)
    return f"✓ {_remote_target(s, target_dir + '/' + remote_file)} → {local_path} ({elapsed:.1f}s)"


# ── 远程列表 ────────────────────────────────────────────────────────

def list_remote(s: ServerConfig, target_dir: str) -> str:
    """列出远程服务器目标目录的文件。"""
    target_dir = _expand(target_dir)

    args = []
    if s.port and s.port != 22:
        args.extend(["-p", str(s.port)])
    args.append(_ssh_dest(s))
    args.extend(["ls", "-lh", target_dir])

    proc = subprocess.run(
        ["ssh", *args],
        capture_output=True, text=True,
    )

    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "ssh 失败")

    output = proc.stdout.strip()
    if not output:
        return f"{_ssh_dest(s)}:{target_dir}/ 是空的"

    return f"{_ssh_dest(s)}:{target_dir}/\n{output}"


# ── 服务器列表 ──────────────────────────────────────────────────────

def format_server_list(servers: dict[str, ServerConfig], target_dir: str) -> str:
    """格式化已配置的服务器列表。"""
    if not servers:
        return "没有配置任何服务器。请编辑 ~/.toss/config.yaml 添加。"

    lines = []
    for name, s in servers.items():
        port_str = f":{s.port}" if s.port and s.port != 22 else ""
        user_str = s.user if s.user else "(默认用户)"
        lines.append(f"  {name:16s} → {user_str}@{s.host}{port_str}")

    header = "已配置的服务器：\n" if len(lines) == 1 else f"已配置 {len(lines)} 台服务器：\n"
    footer = f"\n文件收发目录：{target_dir}"
    return header + "\n".join(lines) + footer
