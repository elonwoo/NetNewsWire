#!/usr/bin/env python3
"""Verifies cursor pagination and the query tool on the live data root.

Every page is fetched through the real MCP stdio transport and compared with a
read-only SQLite connection opened on the same data root:

  * list_articles: full traversal (set equality, order equality, no duplicates,
    stable total_matched), unread_only traversal, `since`, and the null-date
    boundary at the end of the order.
  * query: count, ATTACHed fs.feedSettings join, automatic row cap, multi
    statement rejection, non-SELECT rejection, single-row-too-large and
    multi-row byte truncation.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

from mcp_client import MCPClient, default_binary, tool_text

DEFAULT_ROOT = Path.home() / "Library/Application Support/NetNewsWire"
QUERY_LIMIT = 64 * 1024
PAGE_LIMIT = 100

failures: list[str] = []


def open_read_only(path: Path) -> sqlite3.Connection:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


def record(name: str, passed: bool, detail: str) -> None:
    print(f"case={name} pass={passed} {detail}")
    if not passed:
        failures.append(name)


def walk_list_pages(
    client: MCPClient, arguments: dict, limit: int
) -> tuple[list[str], int, list[int]]:
    ids: list[str] = []
    totals: list[int] = []
    pages = 0
    cursor = None
    while True:
        page_arguments = dict(arguments, limit=limit)
        if cursor is not None:
            page_arguments["after"] = cursor
        call = client.call_tool("list_articles", page_arguments)
        payload = tool_text(call)
        if call["result"].get("isError"):
            raise RuntimeError(f"list_articles 返回 isError：{payload[:200]!r}")
        data = json.loads(payload)
        page = [item["article_id"] for item in data["articles"]]
        if data["returned"] != len(page):
            raise RuntimeError(
                f"returned={data['returned']} 与 articles 数 {len(page)} 不符"
            )
        ids.extend(page)
        totals.append(data["total_matched"])
        pages += 1
        cursor = data.get("next_cursor")
        if not cursor or pages > 1000:
            break
    return ids, pages, totals


def query_call(client: MCPClient, sql: str, limit: int | None = None):
    arguments: dict = {"sql": sql}
    if limit is not None:
        arguments["limit"] = limit
    call = client.call_tool("query", arguments)
    payload = tool_text(call)
    return call, payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=default_binary())
    parser.add_argument("--root", default=str(DEFAULT_ROOT))
    args = parser.parse_args()

    client = MCPClient(args.binary)
    try:
        client.initialize()
        listed = client.list_tools()
        names = [tool["name"] for tool in listed["result"]["tools"]]
        print("tools=", names)
        record(
            "tools_list",
            sorted(names)
            == [
                "get_article",
                "list_articles",
                "list_feeds",
                "query",
                "search_articles",
                "unread_digest",
            ],
            f"names={names}",
        )

        feeds_call = client.call_tool("list_feeds")
        feeds_data = json.loads(tool_text(feeds_call))
        root = Path(feeds_data["data_root"])
        print("data_root=", root)
        database = open_read_only(root / "Accounts/OnMyMac/DB.sqlite3")
        try:
            # --- list_articles: full pagination completeness ---
            ids, pages, totals = walk_list_pages(client, {}, PAGE_LIMIT)
            expected = [
                row[0]
                for row in database.execute(
                    "SELECT articleID FROM articles ORDER BY "
                    "(datePublished IS NULL) ASC, datePublished DESC, articleID DESC"
                )
            ]
            record(
                "live.pagination.all",
                ids == expected
                and set(ids) == set(expected)
                and len(ids) == len(set(ids))
                and all(total == len(expected) for total in totals),
                f"pages={pages} collected={len(ids)} direct={len(expected)} "
                f"set_equal={set(ids) == set(expected)} order_equal={ids == expected} "
                f"duplicates={len(ids) - len(set(ids))} "
                f"totals_stable={len(set(totals)) == 1}",
            )

            # --- list_articles: unread_only pagination completeness ---
            unread_ids, unread_pages, unread_totals = walk_list_pages(
                client, {"unread_only": True}, PAGE_LIMIT
            )
            unread_expected = [
                row[0]
                for row in database.execute(
                    "SELECT a.articleID FROM articles AS a "
                    "LEFT JOIN statuses AS s ON s.articleID = a.articleID "
                    "WHERE s.articleID IS NULL OR COALESCE(s.read, 0) = 0 "
                    "ORDER BY (a.datePublished IS NULL) ASC, a.datePublished DESC, "
                    "a.articleID DESC"
                )
            ]
            record(
                "live.pagination.unread",
                unread_ids == unread_expected
                and set(unread_ids) == set(unread_expected)
                and len(unread_ids) == len(set(unread_ids))
                and all(total == len(unread_expected) for total in unread_totals),
                f"pages={unread_pages} collected={len(unread_ids)} "
                f"direct={len(unread_expected)} "
                f"set_equal={set(unread_ids) == set(unread_expected)} "
                f"order_equal={unread_ids == unread_expected} "
                f"duplicates={len(unread_ids) - len(set(unread_ids))}",
            )

            # --- list_articles: since comparison ---
            since = datetime.now(timezone.utc) - timedelta(days=7)
            since_iso = since.strftime("%Y-%m-%dT%H:%M:%SZ")
            direct_since = database.execute(
                "SELECT count(*) FROM articles WHERE datePublished IS NOT NULL "
                "AND datePublished >= ?",
                (since.timestamp(),),
            ).fetchone()[0]
            since_call = client.call_tool(
                "list_articles", {"since": since_iso, "limit": PAGE_LIMIT}
            )
            since_data = json.loads(tool_text(since_call))
            record(
                "live.since",
                since_call["result"].get("isError") is False
                and since_data["total_matched"] == direct_since
                and all(
                    item["published_at"] is not None
                    for item in since_data["articles"]
                ),
                f"since={since_iso} tool={since_data['total_matched']} "
                f"direct={direct_since} "
                f"equal={since_data['total_matched'] == direct_since} "
                f"returned={since_data['returned']} "
                f"null_dates={sum(1 for item in since_data['articles'] if item['published_at'] is None)}",
            )

            # --- list_articles: null-date boundary at the tail ---
            null_ids = {
                row[0]
                for row in database.execute(
                    "SELECT articleID FROM articles WHERE datePublished IS NULL"
                )
            }
            dated_ids = {
                row[0]
                for row in database.execute(
                    "SELECT articleID FROM articles WHERE datePublished IS NOT NULL"
                )
            }
            tail = ids[-len(null_ids):] if null_ids else []
            tail_ok = sorted(tail) == sorted(null_ids) if null_ids else True
            record(
                "live.cursor.null_boundary",
                null_ids.issubset(set(ids)) and tail_ok,
                f"null_rows={len(null_ids)} reached={null_ids.issubset(set(ids))} "
                f"null_all_at_tail={tail_ok} dated_rows={len(dated_ids)} "
                f"tail={len(tail)}",
            )

            # --- query: count ---
            call, payload = query_call(client, "select count(*) as n from articles")
            data = json.loads(payload)
            direct_count = database.execute(
                "SELECT count(*) FROM articles"
            ).fetchone()[0]
            record(
                "live.query.count",
                call["result"].get("isError") is False
                and data["rows"][0][0] == direct_count,
                f"tool={data['rows'][0][0]} direct={direct_count} "
                f"columns={data['columns']}",
            )

            # --- query: ATTACHed fs.feedSettings join ---
            call, payload = query_call(
                client, "select count(*) as n from fs.feedSettings"
            )
            data = json.loads(payload)
            feed_settings = open_read_only(
                root / "Accounts/OnMyMac/FeedSettings.db"
            )
            try:
                feed_settings_count = feed_settings.execute(
                    "SELECT count(*) FROM feedSettings"
                ).fetchone()[0]
            finally:
                feed_settings.close()
            record(
                "live.query.attach",
                call["result"].get("isError") is False
                and data["rows"][0][0] == feed_settings_count,
                f"tool={data['rows'][0][0]} direct={feed_settings_count} "
                f"columns={data['columns']}",
            )

            # --- query: automatic row cap ---
            call, payload = query_call(
                client, "select articleID, datePublished from articles", 10
            )
            data = json.loads(payload)
            record(
                "live.query.row_limit",
                call["result"].get("isError") is False
                and data["row_count"] == 10
                and len(data["rows"]) == 10
                and data["truncated"] is True
                and data["truncated_reason"] == "row_limit",
                f"row_count={data['row_count']} rows={len(data['rows'])} "
                f"truncated={data['truncated']} "
                f"reason={data['truncated_reason']} "
                f"elapsed_ms={data['elapsed_ms']}",
            )

            # --- query: multi statement rejected ---
            call, payload = query_call(client, "select 1; select 2")
            record(
                "live.query.multiple_statements",
                call["result"].get("isError") is True
                and "multiple_statements" in payload,
                f"isError={call['result'].get('isError')} message={payload[:100]!r}",
            )

            # --- query: non-SELECT rejected ---
            call, payload = query_call(
                client, "update articles set title = 'x'"
            )
            record(
                "live.query.not_select",
                call["result"].get("isError") is True
                and "not_select" in payload,
                f"isError={call['result'].get('isError')} message={payload[:100]!r}",
            )

            # --- query: first row alone above 64 KiB ---
            call, payload = query_call(
                client,
                "select body from search where length(body) > 66000 limit 1",
            )
            record(
                "live.query.first_row_too_large",
                call["result"].get("isError") is True
                and "single_row_too_large" in payload
                and "字节" in payload,
                f"isError={call['result'].get('isError')} "
                f"bytes={len(payload.encode('utf-8'))} message={payload[:140]!r}",
            )

            # --- query: multiple rows beyond 64 KiB are dropped from the tail ---
            call, payload = query_call(
                client,
                "select body from search "
                "where length(body) between 1000 and 2000 limit 100",
            )
            data = json.loads(payload) if not call["result"].get("isError") else {}
            rows = data.get("rows", [])
            payload_bytes = len(payload.encode("utf-8"))
            record(
                "live.query.byte_truncation",
                call["result"].get("isError") is False
                and payload_bytes <= QUERY_LIMIT
                and data.get("row_count") == len(rows)
                and len(rows) < 100
                and data.get("truncated") is True
                and data.get("truncated_reason") == "byte_limit",
                f"bytes={payload_bytes} rows={len(rows)} "
                f"row_count={data.get('row_count')} "
                f"truncated={data.get('truncated')} "
                f"reason={data.get('truncated_reason')}",
            )
        finally:
            database.close()
    finally:
        stderr = client.close()

    print(
        "stderr_first_line=",
        stderr.splitlines()[0] if stderr.splitlines() else "",
    )
    if failures:
        print("FAILURES:", failures)
        print("pagination_verification=failed")
        return 1
    print("pagination_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
