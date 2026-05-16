"""MCP 模式入口。

创建 FastMCP Server，加载所有 capability 的 MCP 工具，
通过 stdio 与 MCP 客户端（如 Claude Code）通信。
"""

from mcp.server.fastmcp import FastMCP


def create_server() -> FastMCP:
    """创建 MCP Server 并注册所有 capability 工具"""
    app = FastMCP("toss")

    # 加载各 capability 的 MCP 工具
    from toss.capabilities.file_transfer import register_mcp
    register_mcp(app)

    return app


def run_server():
    """启动 MCP stdio 服务器"""
    app = create_server()
    app.run(transport="stdio")
