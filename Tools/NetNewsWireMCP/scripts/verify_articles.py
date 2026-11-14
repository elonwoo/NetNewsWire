#!/usr/bin/env python3
"""Compares list_articles/get_article with direct SQL on the live data root."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote

from mcp_client import MCPClient, default_binary, tool_text

DEFAULT_ROOT = Path.home() / "Library/Application Support/NetNewsWire"
LIST_LIMIT = 48 * 1024
GET_LIMIT = 96 * 1024


def open_read_only(path: Path) -> sqlite3.Connection:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


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
        listed = client.list_tools()
        names = [tool["name"] for tool in listed["result"]["tools"]]
        print("tools=", names)
        record(
            "tools_list",
            sorted(names)
            == ["get_article", "list_articles", "list_feeds", "search_articles", "unread_digest"],
            f"names={names}",
        )

        feeds_call = client.call_tool("list_feeds")
        feeds_data = json.loads(tool_text(feeds_call))
        data_root = Path(feeds_data["data_root"])
        print("data_root=", data_root)

        db_path = data_root / "Accounts/OnMyMac/DB.sqlite3"
        database = open_read_only(db_path)
        try:
            # --- list_articles: total_matched vs direct SQL ---
            direct_all = scalar(database, "SELECT count(*) FROM articles")
            call = client.call_tool("list_articles")
            payload = tool_text(call)
            data = json.loads(payload)
            record(
                "list_articles.none",
                call["result"].get("isError") is False
                and data["total_matched"] == direct_all,
                f"tool={data['total_matched']} direct={direct_all} "
                f"equal={data['total_matched'] == direct_all} "
                f"returned={data['returned']} bytes={len(payload.encode('utf-8'))}",
            )
            record(
                "list_articles.none.limit_invariant",
                data["returned"] == len(data["articles"])
                and data["returned"] + data["omitted"] == min(direct_all, 20),
                f"returned={data['returned']} omitted={data['omitted']} "
                f"min={min(direct_all, 20)} articles={len(data['articles'])}",
            )

            feed_id, feed_articles = database.execute(
                "SELECT feedID, count(*) FROM articles GROUP BY feedID "
                "ORDER BY count(*) DESC, feedID ASC LIMIT 1"
            ).fetchone()
            direct_feed = scalar(
                database, "SELECT count(*) FROM articles WHERE feedID = ?", (feed_id,)
            )
            call = client.call_tool("list_articles", {"feed_id": feed_id})
            payload = tool_text(call)
            data = json.loads(payload)
            all_match = all(item["feed_id"] == feed_id for item in data["articles"])
            record(
                "list_articles.feed_id",
                call["result"].get("isError") is False
                and data["total_matched"] == direct_feed
                and all_match,
                f"feed_id={feed_id} tool={data['total_matched']} direct={direct_feed} "
                f"equal={data['total_matched'] == direct_feed} "
                f"all_items_match={all_match} returned={data['returned']}",
            )

            direct_unread = scalar(
                database,
                """
                SELECT count(*)
                FROM articles AS a
                LEFT JOIN statuses AS s ON s.articleID = a.articleID
                WHERE s.articleID IS NULL OR COALESCE(s.read, 0) = 0
                """,
            )
            call = client.call_tool("list_articles", {"unread_only": True})
            payload = tool_text(call)
            data = json.loads(payload)
            all_unread = all(item["read"] is False for item in data["articles"])
            record(
                "list_articles.unread_only",
                call["result"].get("isError") is False
                and data["total_matched"] == direct_unread
                and all_unread,
                f"tool={data['total_matched']} direct={direct_unread} "
                f"equal={data['total_matched'] == direct_unread} "
                f"all_items_unread={all_unread} returned={data['returned']}",
            )

            call = client.call_tool("list_articles", {"limit": 100})
            payload = tool_text(call)
            data = json.loads(payload)
            payload_bytes = len(payload.encode("utf-8"))
            expected = min(data["total_matched"], 100)
            record(
                "list_articles.limit100",
                call["result"].get("isError") is False
                and payload_bytes <= LIST_LIMIT
                and data["returned"] == len(data["articles"])
                and data["returned"] + data["omitted"] == expected,
                f"bytes={payload_bytes} limit={LIST_LIMIT} returned={data['returned']} "
                f"omitted={data['omitted']} total_matched={data['total_matched']} "
                f"expected={expected} "
                f"invariant={data['returned'] + data['omitted'] == expected} "
                f"truncated={data['truncated']}",
            )

            # --- get_article by article_id ---
            row = database.execute(
                """
                SELECT a.articleID, length(CAST(f.body AS BLOB))
                FROM articles AS a
                JOIN search AS f ON f.rowid = a.searchRowID
                WHERE length(f.body) BETWEEN 5000 AND 15000
                ORDER BY a.datePublished DESC, a.articleID DESC
                LIMIT 1
                """
            ).fetchone()
            if row is None:
                record("get_article.article_id", False, "找不到正文 5000..15000 字符的文章")
            else:
                article_id, direct_bytes = row
                call = client.call_tool("get_article", {"article_id": article_id})
                payload = tool_text(call)
                data = json.loads(payload)
                equal = data.get("content_bytes") == direct_bytes
                record(
                    "get_article.article_id",
                    call["result"].get("isError") is False
                    and equal
                    and data.get("content_source") == "search_index_text"
                    and data.get("duplicate_count") == 1
                    and len(payload.encode("utf-8")) <= GET_LIMIT,
                    f"article_id={article_id} content_bytes_tool={data.get('content_bytes')} "
                    f"direct={direct_bytes} equal={equal} "
                    f"source={data.get('content_source')} "
                    f"duplicate_count={data.get('duplicate_count')} "
                    f"content_chars={data.get('content_chars')} "
                    f"bytes={len(payload.encode('utf-8'))}",
                )

            # --- get_article by duplicate url ---
            duplicate = database.execute(
                "SELECT url, count(*) FROM articles "
                "WHERE url IS NOT NULL AND url <> '' GROUP BY url "
                "HAVING count(*) > 1 ORDER BY count(*) DESC, url ASC LIMIT 1"
            ).fetchone()
            if duplicate is None:
                record("get_article.url_duplicate", False, "找不到重复 url")
            else:
                url, direct_count = duplicate
                first = database.execute(
                    "SELECT articleID FROM articles WHERE url = ? "
                    "ORDER BY (datePublished IS NULL) ASC, datePublished DESC, articleID DESC "
                    "LIMIT 1",
                    (url,),
                ).fetchone()[0]
                call = client.call_tool("get_article", {"url": url})
                payload = tool_text(call)
                data = json.loads(payload)
                equal = data.get("duplicate_count") == direct_count
                record(
                    "get_article.url_duplicate",
                    call["result"].get("isError") is False
                    and equal
                    and data.get("article_id") == first,
                    f"url={url} duplicate_count_tool={data.get('duplicate_count')} "
                    f"direct={direct_count} equal={equal} "
                    f"first_tool={data.get('article_id')} first_direct={first} "
                    f"first_equal={data.get('article_id') == first}",
                )

            # --- get_article with empty search.body ---
            empty = database.execute(
                """
                SELECT a.articleID
                FROM articles AS a
                LEFT JOIN search AS f ON f.rowid = a.searchRowID
                WHERE (f.body IS NULL OR f.body = '')
                  AND (a.contentText IS NULL OR a.contentText = '')
                LIMIT 1
                """
            ).fetchone()
            if empty is None:
                record("get_article.empty_body", False, "找不到 search.body 与 contentText 都为空的文章")
            else:
                article_id = empty[0]
                call = client.call_tool("get_article", {"article_id": article_id})
                payload = tool_text(call)
                data = json.loads(payload)
                record(
                    "get_article.empty_body",
                    call["result"].get("isError") is False
                    and data.get("content") == ""
                    and data.get("content_source") == "none"
                    and data.get("content_chars") == 0
                    and data.get("content_bytes") == 0
                    and data.get("content_truncated") is False,
                    f"article_id={article_id} isError={call['result'].get('isError')} "
                    f"content_len={len(data.get('content', ''))} "
                    f"source={data.get('content_source')} "
                    f"chars={data.get('content_chars')} bytes={data.get('content_bytes')}",
                )

            # --- parameter validation ---
            invalid_cases = [
                ("list_articles", {"limit": 0}),
                ("list_articles", {"limit": 101}),
                ("list_articles", {"limit": "abc"}),
                ("list_articles", {"feed_id": "https://missing.example/feed"}),
                ("get_article", {}),
                (
                    "get_article",
                    {"article_id": "x", "url": "https://example.com/x"},
                ),
                ("get_article", {"article_id": "does-not-exist"}),
                ("get_article", {"article_id": row[0] if row else "x", "max_chars": 499}),
                ("get_article", {"article_id": row[0] if row else "x", "max_chars": 32001}),
            ]
            for name, arguments in invalid_cases:
                result = client.call_tool(name, arguments)
                text = tool_text(result)
                passed = result["result"].get("isError") is True
                record(
                    f"validation.{name}.{json.dumps(arguments, sort_keys=True, ensure_ascii=False)}",
                    passed,
                    f"isError={result['result'].get('isError')} message={text[:80]!r}",
                )
        finally:
            database.close()
    finally:
        stderr = client.close()

    print("stderr_first_line=", stderr.splitlines()[0] if stderr.splitlines() else "")
    if failures:
        print("FAILURES:", failures)
        return 1
    print("articles_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
