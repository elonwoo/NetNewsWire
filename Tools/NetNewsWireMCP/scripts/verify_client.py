#!/usr/bin/env python3
"""Registers the built server with Claude Code, verifies it connects, and
removes it again.

This is the P2 client fixture: no temporary database is involved. The only
file it may touch is the user's `~/.claude.json`, and it always removes the
entry again — including on failure — then asserts no `netnewswire` entry is
left behind.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from mcp_client import default_binary

SERVER_NAME = "netnewswire"
CLAUDE_CONFIG = Path.home() / ".claude.json"


def run_claude(*arguments: str, timeout: float = 180) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["claude", *arguments],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def netnewswire_entries(config: dict) -> list[str]:
    found: list[str] = []
    if SERVER_NAME in (config.get("mcpServers") or {}):
        found.append("top-level mcpServers")
    for project, value in (config.get("projects") or {}).items():
        if not isinstance(value, dict):
            continue
        if SERVER_NAME in (value.get("mcpServers") or {}):
            found.append(f"project {project}")
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=default_binary())
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())

    failures: list[str] = []

    def record(name: str, passed: bool, detail: str) -> None:
        print(f"case={name} pass={passed} {detail}")
        if not passed:
            failures.append(name)

    def config_entries() -> list[str]:
        if not CLAUDE_CONFIG.exists():
            return []
        config = json.loads(CLAUDE_CONFIG.read_text(encoding="utf-8"))
        return netnewswire_entries(config)

    before = config_entries()
    if before:
        print(
            "拒绝执行：~/.claude.json 中已存在 netnewswire 条目，"
            f"位置 {before}；不覆盖用户现有配置。"
        )
        return 1

    added = False
    try:
        add = run_claude("mcp", "add", "--scope", "user", SERVER_NAME, "--", binary)
        added = add.returncode == 0
        print("add_stdout=", add.stdout.strip())
        print("add_stderr=", add.stderr.strip())
        record(
            "client.add",
            added,
            f"exit={add.returncode} binary={binary}",
        )

        listed = run_claude("mcp", "list")
        listing = (listed.stdout + listed.stderr).strip()
        print("list_output=", listing)
        matching = [
            line
            for line in listing.splitlines()
            if SERVER_NAME in line or binary in line
        ]
        connected = bool(matching) and any("Connected" in line for line in matching)
        record(
            "client.connected",
            connected,
            f"matching_lines={matching} exit={listed.returncode}",
        )
    finally:
        if added:
            removed = run_claude("mcp", "remove", "--scope", "user", SERVER_NAME)
            print("remove_stdout=", removed.stdout.strip())
            print("remove_stderr=", removed.stderr.strip())

    after_list = run_claude("mcp", "list")
    after_listing = (after_list.stdout + after_list.stderr).strip()
    still_listed = any(
        SERVER_NAME in line for line in after_listing.splitlines()
    )
    record("client.removed", not still_listed, f"list_output={after_listing}")

    leftovers = config_entries()
    record(
        "client.config_clean",
        not leftovers,
        f"~/.claude.json entries={leftovers}",
    )

    if failures:
        print("FAILURES:", failures)
        return 1
    print("client_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
