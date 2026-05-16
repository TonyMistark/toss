"""配置加载、保存、校验。

配置文件 ~/.toss/config.yaml，按 capability 分段：
    file_transfer:
      target_dir: ~/toss
      servers:
        prod:
          host: 10.0.0.50
          user: root
"""

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml


# ── file_transfer 配置类型 ──────────────────────────────────────────

@dataclass
class ServerConfig:
    host: str
    user: str
    port: int = 22


@dataclass
class FileTransferConfig:
    target_dir: str = "~/toss"
    servers: dict[str, ServerConfig] = field(default_factory=dict)

    def get_server(self, name: str) -> Optional[ServerConfig]:
        return self.servers.get(name)

    def server_names(self) -> list[str]:
        return list(self.servers.keys())


# ── 顶层配置 ────────────────────────────────────────────────────────

@dataclass
class Config:
    file_transfer: FileTransferConfig = field(default_factory=FileTransferConfig)


# ── 路径 & IO ───────────────────────────────────────────────────────

def config_path() -> str:
    """配置文件路径 ~/.toss/config.yaml"""
    home = os.environ.get("TOSS_HOME", os.path.expanduser("~"))
    return os.path.join(home, ".toss", "config.yaml")


def _dict_to_file_transfer_config(d: dict) -> FileTransferConfig:
    servers = {}
    for name, s in (d.get("servers") or {}).items():
        servers[name] = ServerConfig(
            host=s["host"],
            user=s.get("user", ""),
            port=s.get("port", 22),
        )
    return FileTransferConfig(
        target_dir=d.get("target_dir", "~/toss"),
        servers=servers,
    )


def load_config() -> Config:
    """加载配置文件，不存在时抛出 FileNotFoundError。"""
    path = config_path()
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"未找到配置文件：{path}\n"
            f"请运行 toss init 或调用 init_config 工具创建"
        )

    with open(path, "r") as f:
        data = yaml.safe_load(f) or {}

    ft_cfg = FileTransferConfig()
    if "file_transfer" in data:
        ft_cfg = _dict_to_file_transfer_config(data["file_transfer"])

    return Config(file_transfer=ft_cfg)


def create_default_config(force: bool = False) -> str:
    """创建默认配置模板，返回配置文件路径。已存在时跳过（除非 force=True）。"""
    path = config_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)

    if os.path.exists(path) and not force:
        return path

    template = (
        "# toss 配置文件\n"
        "# \n"
        "# 每个 capability 各自一个配置段，下面以 file_transfer 为例。\n"
        "# 首次使用前请修改 servers 部分，填上你的服务器信息。\n"
        "\n"
        "# ── 文件传输 ──\n"
        "file_transfer:\n"
        "  target_dir: ~/toss          # 每个服务器上的收发目录\n"
        "  servers:\n"
        "    # prod:\n"
        "    #   host: 10.0.0.50\n"
        "    #   user: root\n"
        "    #   port: 22\n"
        "    #\n"
        "    # nas:\n"
        "    #   host: nas.local\n"
        "    #   user: ice\n"
    )

    with open(path, "w") as f:
        f.write(template)

    return path
