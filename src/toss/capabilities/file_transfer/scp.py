"""SCP/SSH 底层操作。

所有函数返回字符串结果（成功）或抛出异常（失败）。
由上层（CLI / MCP tool handler）负责捕获异常并格式化错误。
"""

import os
import shutil
import subprocess
import tarfile
import tempfile
import time
from pathlib import Path

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


# ── 目录打包 ────────────────────────────────────────────────────────

def _pack_directory(dirpath: str, tmpdir: str) -> str:
    """将目录打包为 tar.gz，返回压缩包路径。"""
    dirname = os.path.basename(os.path.normpath(dirpath))
    tarpath = os.path.join(tmpdir, f"{dirname}.tar.gz")
    with tarfile.open(tarpath, "w:gz") as tar:
        tar.add(dirpath, arcname=dirname)
    return tarpath


def _resolve_files(files: list[str]) -> tuple[list[str], list[str]]:
    """处理文件列表：目录自动打包为 tar.gz。

    返回 (send_list, temp_files)，temp_files 需要发送后清理。
    """
    send_list = []
    temp_files = []
    tmpdir = None

    for f in files:
        f = os.path.normpath(f)
        if not os.path.exists(f):
            raise FileNotFoundError(f"文件不存在：{f}")

        if os.path.isdir(f):
            if tmpdir is None:
                tmpdir = tempfile.mkdtemp(prefix="toss_")
            tarpath = _pack_directory(f, tmpdir)
            send_list.append(tarpath)
            temp_files.append(tarpath)
        else:
            send_list.append(f)

    return send_list, temp_files


# ── 文件发送 ────────────────────────────────────────────────────────

def send_files(s: ServerConfig, files: list[str], target_dir: str) -> str:
    """发送本地文件到服务器。目录自动打包为 tar.gz。返回成功摘要。"""
    target_dir = _expand(target_dir)

    send_list, temp_files = _resolve_files(files)
    started = time.time()

    try:
        args = []
        if s.port and s.port != 22:
            args.extend(["-P", str(s.port)])
        args.extend(send_list)
        args.append(_remote_target(s, target_dir + "/"))

        proc = subprocess.run(
            ["scp", *args],
            capture_output=True, text=True,
        )
        elapsed = time.time() - started

        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or "scp 失败")

        names = "、".join(
            f"{Path(f).name}" + (" (目录已打包)" if f in temp_files else "")
            for f in send_list
        )
        return f"✓ 已发送到 {_remote_target(s, target_dir)} ({elapsed:.1f}s)\n  {names}"

    finally:
        # 清理临时文件
        for tf in temp_files:
            try:
                os.remove(tf)
            except OSError:
                pass
        if temp_files:
            tmpdir = os.path.dirname(temp_files[0])
            try:
                os.rmdir(tmpdir)
            except OSError:
                pass


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
        return "没有配置任何服务器。请编辑 ~/.toss/config.json 添加。"

    lines = []
    for name, s in servers.items():
        port_str = f":{s.port}" if s.port and s.port != 22 else ""
        user_str = s.user if s.user else "(默认用户)"
        lines.append(f"  {name:16s} → {user_str}@{s.host}{port_str}")

    header = "已配置的服务器：\n" if len(lines) == 1 else f"已配置 {len(lines)} 台服务器：\n"
    footer = f"\n文件收发目录：{target_dir}"
    return header + "\n".join(lines) + footer
