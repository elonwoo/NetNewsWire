#!/usr/bin/env python3
"""Compares unread_digest with direct SQL on the live data root.

The tool's own `window.since` / `window.until` are used as the comparison
bounds, so the direct queries see exactly the same inclusive window.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from mcp_client import MCPClient, default_binary, tool_text

DEFAULT_ROOT = Path.home() / "Library/Application Support/NetNewsWire"
DIGEST_LIMIT = 48 * 1024


def open_read_only(path: Path) -> sqlite3.Connection:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


def parse_epoch(value: str) -> float:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    ).timestamp()


def scalar(connection: sqlite3.Connection, sql: str, params: tuple = ()) -> int:
    row = connection.execute(sql, params).fetchone()
    return int(row[0]) if row is not None and row[0] is not None else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=default_binary())
    parser.add_argument("--root", default=str(DEFAULT_ROOT))
    args = parser.parse_args()

    failures: list[str] = []

    def record(name: str, passed: bool, detail: str) -> None:
        print(f"case={name} pass={passed} {detail}")
        if not passed:
            failures.append(name)

    client = MCPClient(args.binary)
    try:
        client.initialize()
        client.list_tools()
        feeds_call = client.call_tool("list_feeds")
        feeds_data = json.loads(tool_text(feeds_call))
        data_root = Path(feeds_data["data_root"])
        print("data_root=", data_root)
        database = open_read_only(data_root / "Accounts/OnMyMac/DB.sqlite3")
        try:
            for days in (1, 7):
                call = client.call_tool("unread_digest", {"days": days})
                payload = tool_text(call)
                if call["result"].get("isError"):
                    record(f"digest.days{days}", False, f"isError payload={payload[:160]!r}")
                    continue
                data = json.loads(payload)
                since = parse_epoch(data["window"]["since"])
                until = parse_epoch(data["window"]["until"])
                totals = data["totals"]
                feeds = data["feeds"]

                direct_articles = scalar(
                    database,
                    "SELECT count(*) FROM articles "
                    "WHERE feedID IS NOT NULL AND feedID <> '' "
                    "AND datePublished IS NOT NULL "
                    "AND datePublished >= ? AND datePublished <= ?",
                    (since, until),
                )
                direct_unread = scalar(
                    database,
                    """
                    SELECT count(*)
                    FROM articles AS a
                    LEFT JOIN statuses AS s ON s.articleID = a.articleID
                    WHERE a.feedID IS NOT NULL AND a.feedID <> ''
                      AND a.datePublished IS NOT NULL
                      AND a.datePublished >= ? AND a.datePublished <= ?
                      AND (s.articleID IS NULL OR COALESCE(s.read, 0) = 0)
                    """,
                    (since, until),
                )
                direct_unread_total = scalar(
                    database,
                    """
                    SELECT count(*)
                    FROM articles AS a
                    LEFT JOIN statuses AS s ON s.articleID = a.articleID
                    WHERE a.feedID IS NOT NULL AND a.feedID <> ''
                      AND (s.articleID IS NULL OR COALESCE(s.read, 0) = 0)
                    """,
                )

                feed_sum = sum(feed["unread_in_window"] for feed in feeds)
                d1 = (
                    feed_sum + data["omitted_unread_in_window"]
                    == totals["unread_in_window"]
                )
                d19 = totals["unread_feeds"] == len(feeds) + data["omitted_feeds"]
                truncated_ok = data["truncated"] == (data["omitted_feeds"] > 0)

                window_ok = (
                    totals["articles_in_window"] == direct_articles
                    and totals["unread_in_window"] == direct_unread
                    and totals["unread_total"] == direct_unread_total
                )

                sort_ok = True
                for previous, current in zip(feeds, feeds[1:]):
                    previous_unread = previous["unread_in_window"]
                    current_unread = current["unread_in_window"]
                    if previous_unread != current_unread:
                        if previous_unread < current_unread:
                            sort_ok = False
                        continue
                    previous_latest = (
                        parse_epoch(previous["latest_published_at"])
                        if previous["latest_published_at"] is not None
                        else None
                    )
                    current_latest = (
                        parse_epoch(current["latest_published_at"])
                        if current["latest_published_at"] is not None
                        else None
                    )
                    if previous_latest is None and current_latest is not None:
                        sort_ok = False
                    elif previous_latest is not None and current_latest is not None:
                        if previous_latest < current_latest:
                            sort_ok = False
                        elif previous_latest == current_latest:
                            if previous["feed_id"] > current["feed_id"]:
                                sort_ok = False
                    elif previous_latest is None and current_latest is None:
                        if previous["feed_id"] > current["feed_id"]:
                            sort_ok = False

                details_ok = True
                for feed in feeds:
                    articles = feed["articles"]
                    if len(articles) > 3:
                        details_ok = False
                    for article in articles:
                        row = database.execute(
                            """
                            SELECT a.datePublished,
                                   (s.articleID IS NULL OR COALESCE(s.read, 0) = 0)
                            FROM articles AS a
                            LEFT JOIN statuses AS s ON s.articleID = a.articleID
                            WHERE a.articleID = ?
                            """,
                            (article["article_id"],),
                        ).fetchone()
                        if row is None:
                            details_ok = False
                            continue
                        date, unread = row
                        if date is None or not (since <= date <= until) or not unread:
                            details_ok = False
                        if article["published_at"] is None and date is not None:
                            details_ok = False

                bytes_ok = len(payload.encode("utf-8")) <= DIGEST_LIMIT
                passed = (
                    window_ok
                    and d1
                    and d19
                    and truncated_ok
                    and sort_ok
                    and details_ok
                    and bytes_ok
                )
                record(
                    f"digest.days{days}",
                    passed,
                    f"articles_window tool={totals['articles_in_window']} "
                    f"direct={direct_articles} "
                    f"unread_window tool={totals['unread_in_window']} direct={direct_unread} "
                    f"unread_total tool={totals['unread_total']} direct={direct_unread_total} "
                    f"equal={window_ok} sum={feed_sum} "
                    f"omitted_unread={data['omitted_unread_in_window']} d1={d1} "
                    f"feeds={len(feeds)} omitted_feeds={data['omitted_feeds']} d19={d19} "
                    f"truncated={data['truncated']} truncated_ok={truncated_ok} "
                    f"sort_ok={sort_ok} details_ok={details_ok} bytes={len(payload.encode('utf-8'))}",
                )
        finally:
            database.close()
    finally:
        stderr = client.close()

    print("stderr_first_line=", stderr.splitlines()[0] if stderr.splitlines() else "")
    if failures:
        print("FAILURES:", failures)
        return 1
    print("digest_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
