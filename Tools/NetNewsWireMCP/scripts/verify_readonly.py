#!/usr/bin/env python3
"""Runs 200 list_feeds calls against a `.backup` snapshot and checks hashes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

from mcp_client import MCPClient, default_binary, tool_text

DEFAULT_ROOT = Path.home() / "Library/Application Support/NetNewsWire"
CALLS = 200


def open_read_only(path: Path) -> sqlite3.Connection:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


def backup_database(source: Path, destination: Path) -> None:
    source_connection = open_read_only(source)
    destination_connection = sqlite3.connect(destination)
    try:
        source_connection.backup(destination_connection)
    finally:
        destination_connection.close()
        source_connection.close()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=default_binary())
    parser.add_argument("--root", default=str(DEFAULT_ROOT))
    args = parser.parse_args()

    source_root = Path(os.path.abspath(os.path.expanduser(args.root)))
    source_account = source_root / "Accounts/OnMyMac"
    required = ["DB.sqlite3", "FeedSettings.db", "Subscriptions.opml"]
    for name in required:
        if not (source_account / name).is_file():
            print(f"FAIL: 缺少源文件 {source_account / name}")
            return 1

    snapshot_parent = Path(tempfile.mkdtemp(prefix="nnw-mcp-snapshot-"))
    snapshot_root = snapshot_parent / "NetNewsWire"
    snapshot_account = snapshot_root / "Accounts/OnMyMac"
    snapshot_account.mkdir(parents=True)
    failures: list[str] = []

    try:
        backup_database(source_account / "DB.sqlite3", snapshot_account / "DB.sqlite3")
        backup_database(
            source_account / "FeedSettings.db", snapshot_account / "FeedSettings.db"
        )
        shutil.copy2(source_account / "Subscriptions.opml", snapshot_account / "Subscriptions.opml")

        files = [
            snapshot_account / "DB.sqlite3",
            snapshot_account / "FeedSettings.db",
            snapshot_account / "Subscriptions.opml",
        ]
        hashes_before = [sha256(path) for path in files]
        mtimes_before = [path.stat().st_mtime_ns for path in files]

        client = MCPClient(
            args.binary, environment={"NNW_MCP_DATA_ROOT": str(snapshot_root)}
        )
        sizes: list[int] = []
        totals: set[str] = set()
        try:
            client.initialize()
            listed = client.list_tools()
            print("tools=", [tool["name"] for tool in listed["result"]["tools"]])
            for _ in range(CALLS):
                result = client.call_tool("list_feeds")
                if result["result"].get("isError"):
                    failures.append("list_feeds 返回 isError")
                    break
                payload = tool_text(result)
                sizes.append(len(payload.encode("utf-8")))
                data = json.loads(payload)
                totals.add(json.dumps(data["totals"], sort_keys=True))
                if data["data_root"] != str(snapshot_root):
                    failures.append("data_root 不是快照根")
                    break
                if not any(entry.get("selected") for entry in data["data_root_candidates"]):
                    failures.append("快照根未被选中")
                    break
        finally:
            stderr = client.close()

        hashes_after = [sha256(path) for path in files]
        mtimes_after = [path.stat().st_mtime_ns for path in files]

        for path, before, after, mtime_before, mtime_after in zip(
            files, hashes_before, hashes_after, mtimes_before, mtimes_after
        ):
            equal = before == after
            mtime_equal = mtime_before == mtime_after
            print(
                f"file={path.name} sha_before={before} sha_after={after} "
                f"sha_equal={equal} mtime_equal={mtime_equal}"
            )
            if not equal:
                failures.append(f"{path.name} 的 sha256 变化")
            if not mtime_equal:
                failures.append(f"{path.name} 的 mtime 变化")

        print(f"calls={CALLS} completed={len(sizes)}")
        if sizes:
            print(f"payload_bytes_min={min(sizes)} payload_bytes_max={max(sizes)}")
        print(f"distinct_totals={len(totals)} totals={sorted(totals)[:1]}")
        print(f"snapshot_stderr_first_line={stderr.splitlines()[0] if stderr.splitlines() else ''}")

        if len(sizes) != CALLS:
            failures.append(f"只完成了 {len(sizes)}/{CALLS} 次调用")
        if len(totals) != 1:
            failures.append("200 次调用返回了不同的 totals")
    finally:
        shutil.rmtree(snapshot_parent, ignore_errors=True)

    if failures:
        print("FAILURES:", failures)
        return 1
    print("readonly_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
