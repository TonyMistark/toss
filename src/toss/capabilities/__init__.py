"""Capability 接口说明

每个 capability 模块放在 capabilities/<name>/ 下，需要提供：

    def register_mcp(app) -> None
        # 在 MCP Server 上注册工具

    def register_cli(subparsers) -> None
        # 注册 CLI 子命令

CLI 和 MCP 共享同一套底层核心逻辑，capability 内部自行组织代码结构。
"""
