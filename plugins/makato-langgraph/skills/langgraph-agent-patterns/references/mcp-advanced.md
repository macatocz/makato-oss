# MCP Advanced Patterns

Reference for multi-server MCP composition, connection error handling, and `MultiServerMCPClient`.
Load this reference **only** when the task involves more than one MCP server, connection retries,
or side-by-side MCP + native tools.

---

## MANDATORY load trigger

Load when the user says any of:
- "connect to multiple MCP servers"
- "compose MCP tools from different servers"
- "MCP connection error" / "MCP timeout"
- "mix MCP tools with native tools"

## Do NOT Load

Do NOT load this reference for the standard single-server MCP pattern — the SKILL.md body covers
that fully.

---

## Multi-Server Composition with MultiServerMCPClient

`MultiServerMCPClient` (from `langchain_mcp_adapters.client`) manages N simultaneous stdio/SSE
sessions and returns a merged flat `list[BaseTool]`:

```python
from langchain_mcp_adapters.client import MultiServerMCPClient
import asyncio

async def build_multi_mcp_agent(prompt: str):
    async with MultiServerMCPClient(
        {
            "filesystem": {
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                "transport": "stdio",
            },
            "github": {
                "url": "http://localhost:8080/mcp",
                "transport": "streamable_http",
            },
        }
    ) as client:
        tools = client.get_tools()          # merged list[BaseTool] from all servers
        # ... build ReAct graph normally with these tools ...
```

Key difference from single-server: `MultiServerMCPClient.get_tools()` is **synchronous** (the
sessions are already open inside the context manager). The single-server pattern uses
`await load_mcp_tools(session)`.

---

## Connection Error Handling

MCP stdio servers can fail silently if the server script crashes at startup. Guard pattern:

```python
async with stdio_client(server_params) as (read, write):
    async with ClientSession(read, write) as session:
        try:
            await session.initialize()
        except Exception as exc:
            # initialize() raises McpError if the subprocess exits non-zero
            raise RuntimeError(f"MCP server failed to start: {exc}") from exc
        tools = await load_mcp_tools(session)
```

The graph itself should use `ToolNode(tools, handle_tool_errors=True)` so individual tool
failures during a run become `ToolMessage` errors the LLM can recover from, rather than
propagating as Python exceptions.

---

## Mixing MCP Tools with Native @tool Functions

MCP tools are `BaseTool` instances. Concatenate lists freely:

```python
native_tools = [calculator, search]          # @tool-decorated
mcp_tools = await load_mcp_tools(session)    # from MCP server
all_tools = native_tools + mcp_tools         # flat merge is all that is needed

llm_with_tools = llm.bind_tools(all_tools)
tool_node = ToolNode(tools=all_tools)
```

No adapter layer needed. `ToolNode` dispatches by `tool_call["name"]` and resolves against the
unified list.

---

## ainvoke vs invoke inside the async context manager

The MCP session must remain open for the lifetime of the graph run. The graph **must** be run
with `await app.ainvoke(...)` — not `app.invoke(...)` — inside an `async with` block.

`app.invoke()` inside an async context is not just slower: it opens a new event loop via
`asyncio.run()`, which **conflicts** with the already-running loop and raises
`RuntimeError: This event loop is already running`.

```python
# CORRECT — stay async throughout
result = await app.ainvoke({"messages": [HumanMessage(content=prompt)]})

# WRONG — will raise RuntimeError inside an async with block
result = app.invoke({"messages": [HumanMessage(content=prompt)]})
```
