#!/usr/bin/env python3
"""Compares list_feeds totals with direct SQL on the same live data root."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from pathlib import Path
from urllib.parse import quote

from mcp_client import MCPClient, default_binary, tool_text

DEFAULT_ROOT = Path.home() / "Library/Application Support/NetNewsWire"


def open_read_only(path: Path) -> sqlite3.Connection:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


def scalar(connection: sqlite3.Connection, sql: str) -> int:
    row = connection.execute(sql).fetchone()
    return int(row[0]) if row is not None and row[0] is not None else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=default_binary())
    parser.add_argument("--root", default=str(DEFAULT_ROOT))
    args = parser.parse_args()

    expected_root = Path(os.path.abspath(os.path.expanduser(args.root)))
    failures: list[str] = []

    client = MCPClient(args.binary)
    try:
        client.initialize()
        listed = client.list_tools()
        print("tools=", [tool["name"] for tool in listed["result"]["tools"]])
        call = client.call_tool("list_feeds")
        payload = tool_text(call)
        data = json.loads(payload)
    finally:
        stderr = client.close()

    if call["result"].get("isError"):
        print("FAIL: list_feeds isError:", payload)
        return 1

    data_root = Path(data["data_root"])
    print("tool_data_root=", data_root)
    print("expected_data_root=", expected_root)
    print("data_root_equal=", data_root == expected_root)
    if data_root != expected_root:
        failures.append("data_root 与预期活跃数据根不一致")

    selected = [c for c in data["data_root_candidates"] if c.get("selected")]
    print("candidate_count=", len(data["data_root_candidates"]), "selected_count=", len(selected))
    if len(selected) != 1:
        failures.append("data_root_candidates 中 selected 数量不是 1")

    db_path = data_root / "Accounts/OnMyMac/DB.sqlite3"
    feed_settings_path = data_root / "Accounts/OnMyMac/FeedSettings.db"
    mtime = db_path.stat().st_mtime
    expected_age = max(0, int(time.time() - mtime))
    age_delta = abs(int(data["data_age_seconds"]) - expected_age)
    print(
        f"data_age_seconds tool={data['data_age_seconds']} direct={expected_age} "
        f"delta={age_delta} within_10s={age_delta <= 10}"
    )
    if age_delta > 10:
        failures.append("data_age_seconds 与 mtime 差值超过 10 秒")

    feed_settings = open_read_only(feed_settings_path)
    database = open_read_only(db_path)
    try:
        direct_feeds = scalar(feed_settings, "SELECT count(*) FROM feedSettings")
        direct_articles = scalar(database, "SELECT count(*) FROM articles")
        direct_unread = scalar(
            database,
            """
            SELECT count(*)
            FROM articles AS a
            LEFT JOIN statuses AS s ON s.articleID = a.articleID
            WHERE s.articleID IS NULL OR COALESCE(s.read, 0) = 0
            """,
        )
        direct_starred = scalar(
            database, "SELECT count(*) FROM statuses WHERE COALESCE(starred, 0) <> 0"
        )
    finally:
        feed_settings.close()
        database.close()

    comparisons = [
        ("totals.feeds", data["totals"]["feeds"], direct_feeds),
        ("totals.articles", data["totals"]["articles"], direct_articles),
        ("totals.unread", data["totals"]["unread"], direct_unread),
        ("totals.starred", data["totals"]["starred"], direct_starred),
    ]
    for name, tool_value, direct_value in comparisons:
        equal = tool_value == direct_value
        print(f"{name} tool={tool_value} direct={direct_value} equal={equal}")
        if not equal:
            failures.append(f"{name} 不一致")

    required_feed_keys = [
        "feed_id",
        "title",
        "folder",
        "home_page_url",
        "article_count",
        "unread_count",
        "latest_published_at",
    ]
    required_candidate_keys = ["path", "exists", "db_mtime", "selected"]
    missing_feed_keys = [
        (feed.get("feed_id"), key)
        for feed in data["feeds"]
        for key in required_feed_keys
        if key not in feed
    ]
    missing_candidate_keys = [
        (candidate.get("path"), key)
        for candidate in data["data_root_candidates"]
        for key in required_candidate_keys
        if key not in candidate
    ]
    null_counts = {
        key: sum(1 for feed in data["feeds"] if feed.get(key) is None)
        for key in ("folder", "home_page_url", "latest_published_at")
    }
    null_mtime_candidates = sum(
        1 for candidate in data["data_root_candidates"] if candidate.get("db_mtime") is None
    )
    print(
        f"nullable_key_checks missing_feed_keys={missing_feed_keys} "
        f"missing_candidate_keys={missing_candidate_keys} "
        f"null_folder={null_counts['folder']} "
        f"null_home_page_url={null_counts['home_page_url']} "
        f"null_latest_published_at={null_counts['latest_published_at']} "
        f"null_candidate_db_mtime={null_mtime_candidates}"
    )
    if missing_feed_keys:
        failures.append(f"feed 缺少键：{missing_feed_keys[:5]}")
    if missing_candidate_keys:
        failures.append(f"候选根缺少键：{missing_candidate_keys[:5]}")

    folder_feed_sum = sum(folder["feed_count"] for folder in data["folders"])
    folder_unread_sum = sum(folder["unread_count"] for folder in data["folders"])
    print(
        f"folders.feed_sum tool={folder_feed_sum} totals={data['totals']['feeds']} "
        f"equal={folder_feed_sum == data['totals']['feeds']}"
    )
    print(
        f"folders.unread_sum tool={folder_unread_sum} totals={data['totals']['unread']} "
        f"equal={folder_unread_sum == data['totals']['unread']}"
    )
    if folder_feed_sum != data["totals"]["feeds"]:
        failures.append("folders[].feed_count 之和 != totals.feeds")
    if folder_unread_sum != data["totals"]["unread"]:
        failures.append("folders[].unread_count 之和 != totals.unread")
    print(
        f"folders_count={data['totals']['folders']} folders_array={len(data['folders'])} "
        f"equal={data['totals']['folders'] == len(data['folders'])}"
    )
    print("feeds_returned=", len(data["feeds"]), "truncated=", data["truncated"], "omitted=", data["omitted"])
    print("payload_bytes=", len(payload.encode("utf-8")), "limit=", 64 * 1024)
    print("warnings=", json.dumps(data["warnings"], ensure_ascii=False))
    print("stderr_first_line=", stderr.splitlines()[0] if stderr.splitlines() else "")

    if failures:
        print("FAILURES:", failures)
        return 1
    print("list_feeds_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
