#!/usr/bin/env python3
"""MCP handshake probe: initialize + tools/list + one list_feeds call."""

from __future__ import annotations

import argparse
import json
import sys

from mcp_client import MCPClient, default_binary, tool_text

EXPECTED_TOOL_NAMES = [
    "list_feeds",
    "list_articles",
    "get_article",
    "search_articles",
    "unread_digest",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=default_binary())
    args = parser.parse_args()

    failures: list[str] = []
    client = MCPClient(args.binary)
    try:
        initialize = client.initialize()
        print("initialize:", json.dumps(initialize, ensure_ascii=False))

        listed = client.list_tools()
        print("tools/list:", json.dumps(listed, ensure_ascii=False))

        tools = listed["result"]["tools"]
        names = [tool.get("name") for tool in tools]
        if len(tools) != len(EXPECTED_TOOL_NAMES):
            failures.append(
                f"tools/list 工具数 {len(tools)} != 期望 {len(EXPECTED_TOOL_NAMES)}"
            )
        if sorted(names) != sorted(EXPECTED_TOOL_NAMES):
            failures.append(f"tools/list 工具名 {names} != 期望 {EXPECTED_TOOL_NAMES}")
        for tool in tools:
            annotations = tool.get("annotations", {})
            if annotations.get("readOnlyHint") is not True:
                failures.append(f"{tool.get('name')} 缺少 readOnlyHint=true")
            if annotations.get("destructiveHint") is not False:
                failures.append(f"{tool.get('name')} 缺少 destructiveHint=false")
            if annotations.get("idempotentHint") is not True:
                failures.append(f"{tool.get('name')} 缺少 idempotentHint=true")
            if annotations.get("openWorldHint") is not False:
                failures.append(f"{tool.get('name')} 缺少 openWorldHint=false")
            print(
                f"tool={tool.get('name')} readOnlyHint={annotations.get('readOnlyHint')} "
                f"destructiveHint={annotations.get('destructiveHint')} "
                f"idempotentHint={annotations.get('idempotentHint')} "
                f"openWorldHint={annotations.get('openWorldHint')}"
            )

        call = client.call_tool("list_feeds")
        payload = tool_text(call)
        data = json.loads(payload)
        print(
            "list_feeds:",
            json.dumps(
                {
                    "isError": call["result"].get("isError"),
                    "bytes": len(payload.encode("utf-8")),
                    "totals": data.get("totals"),
                    "data_root": data.get("data_root"),
                },
                ensure_ascii=False,
            ),
        )
        if call["result"].get("isError"):
            failures.append("list_feeds 返回 isError")
    finally:
        stderr = client.close()

    diagnostic_lines = [line for line in stderr.splitlines() if line.strip()]
    print(f"stderr_lines={len(diagnostic_lines)}")
    for line in diagnostic_lines:
        print("stderr:", line)

    if failures:
        for failure in failures:
            print("FAIL:", failure)
        return 1
    print("handshake=ok tool_count=%d tools=%s" % (len(EXPECTED_TOOL_NAMES), names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
