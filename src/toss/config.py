"""配置加载、保存、校验。

配置文件 ~/.toss/config.json，按 capability 分段：
{
  "file_transfer": {
    "target_dir": "~/toss",
    "servers": {
      "prod": {
        "host": "10.0.0.50",
        "user": "root"
      }
    }
  }
}
"""

import json
import os
from dataclasses import dataclass, field
from typing import Optional


# ── file_transfer 配置类型 ──────────────────────────────────────────

@dataclass
class ServerConfig:
    host: str
    user: str
    port: int = 22
    target_dir: Optional[str] = None  # 覆盖全局 target_dir，不填则继承


@dataclass
class FileTransferConfig:
    target_dir: str = "/tmp"
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
    home = os.environ.get("TOSS_HOME", os.path.expanduser("~"))
    return os.path.join(home, ".toss", "config.json")


def _dict_to_file_transfer_config(d: dict) -> FileTransferConfig:
    servers = {}
    for name, s in (d.get("servers") or {}).items():
        servers[name] = ServerConfig(
            host=s["host"],
            user=s.get("user", ""),
            port=s.get("port", 22),
            target_dir=s.get("target_dir"),
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
        data = json.load(f)

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

    template = {
        "file_transfer": {
            "target_dir": "~/toss",
            "servers": {}
        }
    }

    with open(path, "w") as f:
        json.dump(template, f, indent=2, ensure_ascii=False)
        f.write("\n")

    return path
