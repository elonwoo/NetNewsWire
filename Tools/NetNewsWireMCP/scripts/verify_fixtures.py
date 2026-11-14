#!/usr/bin/env python3
"""Runs the P0/P1 fixture acceptance cases against the built binary."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from mcp_client import MCPClient, default_binary, run_startup, tool_text

PACKAGE = Path(__file__).resolve().parent.parent
SCHEMA = (PACKAGE / "Tests/NetNewsWireMCPTests/Fixtures/schema.sql").read_text()
SEED = (PACKAGE / "Tests/NetNewsWireMCPTests/Fixtures/seed.sql").read_text()

JOURNAL_MAGIC = bytes.fromhex("d9d505f920a163d7")
ZERO_MAGIC = b"\x00" * 8

# Opens a real write transaction and keeps it open. `nosync` makes SQLite write
# the journal magic immediately (synchronous=OFF); the default mode leaves the
# magic zeroed until commit, which is what a process killed mid-transaction
# leaves behind.
JOURNAL_WRITER = r"""
import sqlite3, sys, time
database, mode = sys.argv[1], sys.argv[2]
connection = sqlite3.connect(database, isolation_level=None)
connection.execute("PRAGMA journal_mode=DELETE")
if mode == "nosync":
    connection.execute("PRAGMA synchronous=OFF")
connection.execute("PRAGMA cache_size=1")
connection.execute("BEGIN IMMEDIATE")
for index in range(400):
    connection.execute(
        "INSERT INTO statuses (articleID, read, starred, dateArrived) VALUES (?, 0, 0, 0)",
        ("journal-%s-%d" % (mode, index),),
    )
time.sleep(60)
"""

STANDARD_OPML = """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.1">
<head><title>Test</title></head>
<body>
    <outline text="News" title="News">
        <outline text="Alpha OPML" title="Alpha OPML" type="rss" htmlUrl="https://opml.example/a" xmlUrl="https://a.example/feed"/>
        <outline text="Bee Text" title="Bee Title" type="rss" htmlUrl="https://opml.example/b" xmlUrl="https://b.example/feed"/>
    </outline>
    <outline text="Tech" title="Tech">
        <outline text="" title="Cee Title" type="rss" htmlUrl="" xmlUrl="https://c.example/feed"/>
        <outline text="Dee OPML" title="Dee OPML" type="rss" xmlUrl="https://d.example/feed"/>
    </outline>
    <outline text="Empty" title="Empty"></outline>
</body>
</opml>
"""

results: list[tuple[str, bool, str]] = []


def record(name: str, passed: bool, detail: str) -> None:
    results.append((name, passed, detail))
    print(f"case={name} pass={passed} {detail}")


def make_account(root: Path) -> Path:
    account = root / "Accounts/OnMyMac"
    account.mkdir(parents=True)
    return account


def write_database(path: Path, schema: str, seed: str | None = None) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.executescript(schema)
        if seed:
            connection.executescript(seed)
        connection.commit()
    finally:
        connection.close()


def standard_root(base: Path) -> Path:
    root = base / "NetNewsWire"
    account = make_account(root)
    write_database(account / "DB.sqlite3", SCHEMA, SEED)
    write_database(account / "FeedSettings.db", SCHEMA, SEED)
    (account / "Subscriptions.opml").write_text(STANDARD_OPML, encoding="utf-8")
    return root


def startup_case(
    binary: str,
    name: str,
    environment: dict[str, str],
    expected_code: int,
    stderr_contains: list[str],
) -> None:
    process = run_startup(binary, environment)
    missing = [text for text in stderr_contains if text not in process.stderr]
    passed = (
        process.returncode == expected_code
        and process.stdout == ""
        and not missing
    )
    first_line = next((line for line in process.stderr.splitlines() if line.strip()), "")
    detail = (
        f"exit={process.returncode} expected={expected_code} "
        f"stdout_bytes={len(process.stdout.encode('utf-8'))} "
        f"missing_stderr={missing} stderr_first={first_line!r}"
    )
    record(name, passed, detail)


def make_temporary_root(prefix: str) -> tuple[Path, Path]:
    base = Path(tempfile.mkdtemp(prefix=prefix))
    return base, base / "NetNewsWire"


def case_override_missing(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-override-")
    try:
        missing = base / "does-not-exist"
        startup_case(
            binary,
            "env_override_missing",
            {"NNW_MCP_DATA_ROOT": str(missing)},
            4,
            [str(missing)],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_only_other_account(binary: str) -> None:
    base, root = make_temporary_root("nnw-mcp-otheracct-")
    try:
        (root / "Accounts/Feedly").mkdir(parents=True)
        startup_case(
            binary,
            "only_other_account",
            {"NNW_MCP_DATA_ROOT": str(root)},
            4,
            ["暂不支持", "Feedly"],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_missing_file(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-missingfile-")
    try:
        root = standard_root(base)
        (root / "Accounts/OnMyMac/Subscriptions.opml").unlink()
        startup_case(
            binary,
            "missing_required_file",
            {"NNW_MCP_DATA_ROOT": str(root)},
            4,
            ["Subscriptions.opml"],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_zero_byte_database(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-zerodb-")
    try:
        root = standard_root(base)
        (root / "Accounts/OnMyMac/DB.sqlite3").write_bytes(b"")
        startup_case(
            binary,
            "zero_byte_database",
            {"NNW_MCP_DATA_ROOT": str(root)},
            5,
            ["0 字节"],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_non_database(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-notadb-")
    try:
        root = standard_root(base)
        (root / "Accounts/OnMyMac/DB.sqlite3").write_text(
            "this is not a sqlite database", encoding="utf-8"
        )
        startup_case(
            binary,
            "non_database_file",
            {"NNW_MCP_DATA_ROOT": str(root)},
            5,
            [],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_unreadable_database(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-unreadable-")
    try:
        root = standard_root(base)
        database = root / "Accounts/OnMyMac/DB.sqlite3"
        os.chmod(database, 0)
        try:
            startup_case(
                binary,
                "unreadable_database",
                {"NNW_MCP_DATA_ROOT": str(root)},
                5,
                [],
            )
        finally:
            os.chmod(database, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_schema(binary: str, name: str, mutate) -> None:
    base, _ = make_temporary_root(f"nnw-mcp-{name}-")
    try:
        root = base / "NetNewsWire"
        account = make_account(root)
        database = account / "DB.sqlite3"
        write_database(database, SCHEMA)
        mutate(database)
        write_database(account / "FeedSettings.db", SCHEMA)
        (account / "Subscriptions.opml").write_text(STANDARD_OPML, encoding="utf-8")
        startup_case(
            binary,
            name,
            {"NNW_MCP_DATA_ROOT": str(root)},
            3,
            [],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def mutate_missing_column(database: Path) -> None:
    modified = SCHEMA.replace("    authors TEXT,\n", "")
    assert modified != SCHEMA
    database.unlink()
    write_database(database, modified)


def mutate_not_fts4(database: Path) -> None:
    modified = SCHEMA.replace(
        "CREATE VIRTUAL TABLE search USING fts4(title, body);",
        "CREATE TABLE search (title TEXT, body TEXT);",
    )
    assert modified != SCHEMA
    database.unlink()
    write_database(database, modified)


def mutate_no_trigger(database: Path) -> None:
    connection = sqlite3.connect(database)
    try:
        connection.execute("DROP TRIGGER articles_after_delete_trigger_delete_search_text")
        connection.commit()
    finally:
        connection.close()


def case_opml(binary: str, name: str, opml_bytes: bytes | None, unreadable: bool = False) -> None:
    base, _ = make_temporary_root(f"nnw-mcp-{name}-")
    try:
        root = standard_root(base)
        opml = root / "Accounts/OnMyMac/Subscriptions.opml"
        if opml_bytes is not None:
            opml.write_bytes(opml_bytes)
        if unreadable:
            os.chmod(opml, 0)
            try:
                startup_case(
                    binary, name, {"NNW_MCP_DATA_ROOT": str(root)}, 6, []
                )
            finally:
                os.chmod(opml, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
        else:
            startup_case(binary, name, {"NNW_MCP_DATA_ROOT": str(root)}, 6, [])
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_exit_code_priority(binary: str) -> None:
    # Exit 4 (missing file) wins over exit 5 (0-byte database).
    base, _ = make_temporary_root("nnw-mcp-priority45-")
    try:
        root = standard_root(base)
        (root / "Accounts/OnMyMac/Subscriptions.opml").unlink()
        (root / "Accounts/OnMyMac/DB.sqlite3").write_bytes(b"")
        startup_case(
            binary,
            "priority_4_before_5",
            {"NNW_MCP_DATA_ROOT": str(root)},
            4,
            ["Subscriptions.opml"],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # Exit 5 (0-byte database) wins over exit 3 (bad schema) and exit 6 (bad OPML).
    base, _ = make_temporary_root("nnw-mcp-priority53-")
    try:
        root = standard_root(base)
        (root / "Accounts/OnMyMac/DB.sqlite3").write_bytes(b"")
        (root / "Accounts/OnMyMac/Subscriptions.opml").write_text(
            "<opml><body><outline></body></opml>", encoding="utf-8"
        )
        startup_case(
            binary,
            "priority_5_before_3_and_6",
            {"NNW_MCP_DATA_ROOT": str(root)},
            5,
            ["0 字节"],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # Exit 3 (bad schema) wins over exit 6 (bad OPML).
    base, _ = make_temporary_root("nnw-mcp-priority36-")
    try:
        root = base / "NetNewsWire"
        account = make_account(root)
        database = account / "DB.sqlite3"
        write_database(database, SCHEMA)
        mutate_missing_column(database)
        write_database(account / "FeedSettings.db", SCHEMA)
        (account / "Subscriptions.opml").write_text(
            "<opml><body><outline></body></opml>", encoding="utf-8"
        )
        startup_case(
            binary,
            "priority_3_before_6",
            {"NNW_MCP_DATA_ROOT": str(root)},
            3,
            ["authors"],
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_mixed_accounts_and_64kib(binary: str) -> None:
    # Mixed accounts.
    base, _ = make_temporary_root("nnw-mcp-mixed-")
    try:
        root = standard_root(base)
        (root / "Accounts/Feedly").mkdir()
        client = MCPClient(binary, {"NNW_MCP_DATA_ROOT": str(root)})
        try:
            client.initialize()
            result = client.call_tool("list_feeds")
            payload = tool_text(result)
            data = json.loads(payload)
            stderr = client.close()
        except Exception:
            client.process.kill()
            raise
        passed = (
            result["result"].get("isError") is False
            and data["unsupported_accounts"] == ["Feedly"]
            and "暂不支持账户：Feedly" in data["warnings"]
            and data["totals"]["feeds"] == 4
            and "暂不支持账户：Feedly" in stderr
        )
        record(
            "mixed_accounts",
            passed,
            f"unsupported={data['unsupported_accounts']} "
            f"warnings={json.dumps(data['warnings'], ensure_ascii=False)} "
            f"totals_feeds={data['totals']['feeds']} stderr_has_warning="
            f"{'暂不支持账户：Feedly' in stderr}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # 64 KiB truncation.
    base, root = make_temporary_root("nnw-mcp-64k-")
    try:
        account = make_account(root)
        write_database(account / "DB.sqlite3", SCHEMA)
        feed_settings = sqlite3.connect(account / "FeedSettings.db")
        try:
            feed_settings.executescript(SCHEMA)
            rows = []
            outlines = []
            for index in range(500):
                url = f"https://feed{index}.example/rss"
                title = f"Feed {index} " + "long-name-" * 6
                rows.append((url, url, title, f"https://feed{index}.example/", None))
                outlines.append(
                    f'<outline text="{title}" title="{title}" type="rss" xmlUrl="{url}"/>'
                )
            feed_settings.executemany(
                "INSERT INTO feedSettings "
                "(feedURL, feedID, editedName, homePageURL, folderRelationship) "
                "VALUES (?, ?, ?, ?, ?)",
                rows,
            )
            feed_settings.commit()
        finally:
            feed_settings.close()
        (account / "Subscriptions.opml").write_text(
            '<?xml version="1.0"?><opml version="1.1"><head/><body>'
            '<outline text="Big" title="Big">' + "\n".join(outlines)
            + "</outline></body></opml>",
            encoding="utf-8",
        )

        client = MCPClient(binary, {"NNW_MCP_DATA_ROOT": str(root)})
        try:
            client.initialize()
            result = client.call_tool("list_feeds")
            payload = tool_text(result)
            data = json.loads(payload)
        finally:
            client.close()

        payload_bytes = len(payload.encode("utf-8"))
        omitted = data["omitted"]
        returned = len(data["feeds"])
        folder = data["folders"][0] if data["folders"] else {}
        passed = (
            result["result"].get("isError") is False
            and payload_bytes <= 64 * 1024
            and data["truncated"] is True
            and omitted > 0
            and returned + omitted == 500
            and data["totals"]["feeds"] == 500
            and data["totals"]["folders"] == 1
            and folder.get("feed_count") == 500
            and folder.get("unread_count") == 0
        )
        record(
            "list_feeds_64kib_truncation",
            passed,
            f"bytes={payload_bytes} returned={returned} omitted={omitted} "
            f"totals={json.dumps(data['totals'])} folder={json.dumps(folder, ensure_ascii=False)}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def wait_for_journal(
    database: Path, expected_magic: bytes, timeout: float = 20
) -> bytes | None:
    journal = Path(str(database) + "-journal")
    deadline = time.time() + timeout
    last_seen = b""
    while time.time() < deadline:
        if journal.is_file():
            data = journal.read_bytes()[:8]
            last_seen = data
            if len(data) == 8 and data == expected_magic:
                return data
        time.sleep(0.02)
    print(
        f"journal_wait timed_out database={database} "
        f"exists={journal.is_file()} last_magic={last_seen.hex()}"
    )
    return None


def case_journal(binary: str) -> None:
    branches = [
        ("journal_zero_magic_remnant", "default", ZERO_MAGIC, 0),
        ("journal_valid_magic_hot", "nosync", JOURNAL_MAGIC, 5),
    ]
    for name, mode, expected_magic, expected_code in branches:
        base, _ = make_temporary_root(f"nnw-mcp-{name}-")
        writer = None
        try:
            root = standard_root(base)
            database = root / "Accounts/OnMyMac/DB.sqlite3"
            journal = Path(str(database) + "-journal")

            writer = subprocess.Popen(
                [sys.executable, "-c", JOURNAL_WRITER, str(database), mode],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            observed = wait_for_journal(database, expected_magic)
            if observed is None:
                stderr = ""
                if writer.poll() is not None:
                    stderr = writer.stderr.read() if writer.stderr else ""
                record(
                    name,
                    False,
                    f"未留下预期的 journal：expected_magic={expected_magic.hex()} "
                    f"writer_exit={writer.poll()} writer_stderr={stderr[:200]!r}",
                )
                continue

            writer.kill()
            writer.wait(timeout=10)
            writer = None

            retained_before = journal.is_file()
            startup = run_startup(binary, {"NNW_MCP_DATA_ROOT": str(root)})
            retained_after = journal.is_file()
            stderr_ok = str(journal) in startup.stderr if expected_code == 0 else True
            passed = (
                observed == expected_magic
                and retained_before
                and startup.returncode == expected_code
                and startup.stdout == ""
                and stderr_ok
                and retained_after
            )
            first_line = next(
                (line for line in startup.stderr.splitlines() if line.strip()), ""
            )
            record(
                name,
                passed,
                f"magic={observed.hex()} expected_magic={expected_magic.hex()} "
                f"exit={startup.returncode} expected={expected_code} "
                f"stdout_bytes={len(startup.stdout.encode('utf-8'))} "
                f"stderr_has_journal_path={str(journal) in startup.stderr} "
                f"journal_retained={retained_after} stderr_first={first_line!r}",
            )
        finally:
            if writer is not None:
                writer.kill()
                writer.wait(timeout=10)
            shutil.rmtree(base, ignore_errors=True)


def case_feed_url_null_and_empty(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-feedurl-")
    try:
        root = standard_root(base)
        connection = sqlite3.connect(root / "Accounts/OnMyMac/FeedSettings.db")
        try:
            connection.execute(
                "INSERT INTO feedSettings (feedURL, feedID, editedName) "
                "VALUES (NULL, 'null-url', 'Null URL')"
            )
            connection.execute(
                "INSERT INTO feedSettings (feedURL, feedID, editedName) "
                "VALUES ('', 'empty-url', 'Empty URL')"
            )
            connection.commit()
        finally:
            connection.close()

        client = MCPClient(binary, {"NNW_MCP_DATA_ROOT": str(root)})
        try:
            client.initialize()
            result = client.call_tool("list_feeds")
            payload = tool_text(result)
            data = json.loads(payload)
        finally:
            client.close()

        feeds = data["feeds"]
        titles = {feed.get("title") for feed in feeds}
        feed_ids = {feed.get("feed_id") for feed in feeds}
        passed = (
            result["result"].get("isError") is False
            and data["totals"]["feeds"] == 4
            and len(feeds) == 4
            and "" not in feed_ids
            and None not in feed_ids
            and "Null URL" not in titles
            and "Empty URL" not in titles
        )
        record(
            "feed_url_null_and_empty",
            passed,
            f"totals_feeds={data['totals']['feeds']} feeds={len(feeds)} "
            f"feed_ids={sorted(feed_ids)} "
            f"dropped_titles_present={sorted(titles & {'Null URL', 'Empty URL'})}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def add_article(
    account: Path,
    article_id: str,
    feed_id: str,
    *,
    search_row: int | None = None,
    search_title: str = "",
    body: str | None = None,
    content_text: str = "",
    published: float | None = 1700000400,
    url: str | None = None,
    external_url: str | None = None,
    authors: str | None = None,
    status: tuple[int, int, float] | None = None,
) -> None:
    connection = sqlite3.connect(account / "DB.sqlite3")
    try:
        connection.execute(
            "INSERT INTO articles "
            "(articleID, feedID, uniqueID, title, contentText, url, externalURL, "
            "datePublished, searchRowID, authors) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                article_id,
                feed_id,
                article_id,
                search_title,
                content_text,
                url,
                external_url,
                published,
                search_row,
                authors,
            ),
        )
        if search_row is not None:
            connection.execute(
                "INSERT INTO search (docid, title, body) VALUES (?, ?, ?)",
                (search_row, search_title, body if body is not None else ""),
            )
        if status is not None:
            read, starred, arrived = status
            connection.execute(
                "INSERT INTO statuses (articleID, read, starred, dateArrived) "
                "VALUES (?, ?, ?, ?)",
                (article_id, read, starred, arrived),
            )
        connection.commit()
    finally:
        connection.close()


def p1_call(binary: str, root: Path, name: str, arguments: dict | None):
    client = MCPClient(binary, {"NNW_MCP_DATA_ROOT": str(root)})
    try:
        client.initialize()
        result = client.call_tool(name, arguments)
        payload = tool_text(result)
        return result, payload, json.loads(payload)
    finally:
        client.close()


def p1_call_raw(binary: str, root: Path, name: str, arguments: dict | None):
    """Like `p1_call`, but tolerates a plain-text `isError` payload."""
    client = MCPClient(binary, {"NNW_MCP_DATA_ROOT": str(root)})
    try:
        client.initialize()
        result = client.call_tool(name, arguments)
        return result, tool_text(result)
    finally:
        client.close()


def case_p1_content_text_fallback(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-p1-contenttext-")
    try:
        root = standard_root(base)
        account = root / "Accounts/OnMyMac"
        text = "Fallback 正文 only in contentText"
        add_article(
            account,
            "ct1",
            "https://a.example/feed",
            content_text=text,
            status=(0, 0, 1700000400),
        )
        result, payload, data = p1_call(binary, root, "get_article", {"article_id": "ct1"})
        passed = (
            result["result"].get("isError") is False
            and data.get("content_source") == "contentText"
            and data.get("content") == text
            and data.get("content_chars") == len(text)
            and data.get("content_total_chars") == len(text)
            and data.get("content_truncated") is False
        )
        record(
            "p1_content_text_fallback",
            passed,
            f"isError={result['result'].get('isError')} "
            f"content_source={data.get('content_source')} "
            f"content_equal={data.get('content') == text} "
            f"chars={data.get('content_chars')}/{data.get('content_total_chars')} "
            f"truncated={data.get('content_truncated')}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_p1_statuses_missing(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-p1-nostatus-")
    try:
        root = standard_root(base)
        account = root / "Accounts/OnMyMac"
        feed_id = "https://a.example/feed"
        add_article(
            account,
            "ns1",
            feed_id,
            search_row=7,
            search_title="No status",
            body="No status body",
            published=1700000400,
            status=None,
        )
        result, payload, data = p1_call(
            binary, root, "list_articles", {"feed_id": feed_id, "unread_only": True}
        )
        items = [item for item in data.get("articles", []) if item.get("article_id") == "ns1"]
        item_read = items[0].get("read") if items else None
        detail_result, detail_payload, detail = p1_call(
            binary, root, "get_article", {"article_id": "ns1"}
        )
        passed = (
            result["result"].get("isError") is False
            and len(items) == 1
            and item_read is False
            and detail_result["result"].get("isError") is False
            and detail.get("read") is False
            and detail.get("starred") is False
            and detail.get("arrived_at") is None
        )
        record(
            "p1_statuses_missing_unread",
            passed,
            f"unread_only_contains={len(items)} item_read={item_read} "
            f"get_read={detail.get('read')} get_starred={detail.get('starred')} "
            f"arrived_at={detail.get('arrived_at')}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_p1_get_article_96kib(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-p1-96kib-")
    try:
        root = standard_root(base)
        account = root / "Accounts/OnMyMac"
        body = "😀" * 32000
        add_article(
            account,
            "big1",
            "https://a.example/feed",
            search_row=8,
            search_title="Emoji",
            body=body,
            published=1700000400,
        )
        result, payload, data = p1_call(
            binary, root, "get_article", {"article_id": "big1", "max_chars": 32000}
        )
        content = data.get("content", "")
        payload_bytes = len(payload.encode("utf-8"))
        passed = (
            result["result"].get("isError") is False
            and payload_bytes <= 96 * 1024
            and data.get("content_truncated") is True
            and data.get("content_total_chars") == 32000
            and data.get("content_chars", 0) < data.get("content_total_chars", 0)
            and data.get("content_bytes") == len(content.encode("utf-8"))
            and data.get("content_chars") == len(content)
        )
        record(
            "p1_get_article_96kib",
            passed,
            f"bytes={payload_bytes} limit={96 * 1024} "
            f"chars={data.get('content_chars')}/{data.get('content_total_chars')} "
            f"content_bytes={data.get('content_bytes')} "
            f"truncated={data.get('content_truncated')}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_p1_orphan_feed_id(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-p1-orphan-")
    try:
        root = standard_root(base)
        account = root / "Accounts/OnMyMac"
        orphan = "https://orphan.example/feed"
        add_article(
            account,
            "orphan1",
            orphan,
            search_row=7,
            search_title="Orphan",
            body="orphan body",
            published=1700000400,
            status=(0, 0, 1700000400),
        )
        connection = sqlite3.connect(account / "FeedSettings.db")
        try:
            connection.execute(
                "INSERT INTO feedSettings (feedURL, feedID, editedName) "
                "VALUES (?, ?, ?)",
                ("https://settings-only.example/feed", "settings-feed-id", "Settings Only"),
            )
            connection.commit()
        finally:
            connection.close()

        listing_result, _, listing = p1_call(binary, root, "list_articles", None)
        orphan_items = [
            item
            for item in listing.get("articles", [])
            if item.get("article_id") == "orphan1"
        ]
        item = orphan_items[0] if orphan_items else {}

        filter_result, _, filtered = p1_call(
            binary, root, "list_articles", {"feed_id": orphan}
        )

        by_id_result, _, by_id = p1_call(
            binary, root, "list_articles", {"feed_id": "settings-feed-id"}
        )
        url_result, url_payload = p1_call_raw(
            binary, root, "list_articles", {"feed_id": "https://settings-only.example/feed"}
        )

        passed = (
            listing_result["result"].get("isError") is False
            and len(orphan_items) == 1
            and item.get("feed_title") == orphan
            and item.get("folder") is None
            and filter_result["result"].get("isError") is False
            and filtered.get("total_matched") == 1
            and [entry.get("article_id") for entry in filtered.get("articles", [])]
            == ["orphan1"]
            and by_id_result["result"].get("isError") is False
            and by_id.get("total_matched") == 0
            and url_result["result"].get("isError") is True
            and "未知 feed_id" in url_payload
        )
        record(
            "p1_orphan_feed_id",
            passed,
            f"listed={len(orphan_items)} feed_title={item.get('feed_title')!r} "
            f"folder={item.get('folder')!r} "
            f"filter_total={filtered.get('total_matched')} "
            f"by_feed_id_total={by_id.get('total_matched')} "
            f"feed_url_isError={url_result['result'].get('isError')} "
            f"feed_url_message={url_payload[:60]!r}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_p1_author_shapes(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-p1-authors-")
    try:
        root = standard_root(base)
        account = root / "Accounts/OnMyMac"
        feed_id = "https://a.example/feed"
        rows = {
            "au-empty": "[]",
            "au-invalid": "not json",
            "au-mixed": '[{"name":"A"},{"nope":1}]',
            "au-null": None,
        }
        for index, (article_id, authors) in enumerate(rows.items()):
            add_article(
                account,
                article_id,
                feed_id,
                published=1700000400 + index,
                authors=authors,
                status=(0, 0, 1700000400 + index),
            )

        expected_detail = {
            "au-empty": [],
            "au-invalid": None,
            "au-mixed": ["A"],
            "au-null": None,
        }
        detail_ok = True
        detail_observed = {}
        for article_id, expected in expected_detail.items():
            result, _, data = p1_call(binary, root, "get_article", {"article_id": article_id})
            observed = data.get("authors")
            detail_observed[article_id] = observed
            if result["result"].get("isError") is not False or observed != expected:
                detail_ok = False

        listing_result, _, listing = p1_call(
            binary, root, "list_articles", {"feed_id": feed_id, "limit": 100}
        )
        author_by_id = {
            item.get("article_id"): item.get("author")
            for item in listing.get("articles", [])
        }
        expected_listing = {
            "au-empty": None,
            "au-invalid": None,
            "au-mixed": "A",
            "au-null": None,
        }
        listing_ok = all(
            author_by_id.get(article_id) == expected
            for article_id, expected in expected_listing.items()
        )
        passed = (
            detail_ok
            and listing_result["result"].get("isError") is False
            and listing_ok
        )
        record(
            "p1_author_shapes",
            passed,
            f"detail={detail_observed} detail_ok={detail_ok} "
            f"listing={ {k: author_by_id.get(k) for k in expected_listing} } "
            f"listing_ok={listing_ok}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_p0_root_level_feed(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-p0-rootfeed-")
    try:
        root = base / "NetNewsWire"
        account = make_account(root)
        write_database(account / "DB.sqlite3", SCHEMA, None)
        write_database(account / "FeedSettings.db", SCHEMA, None)
        (account / "Subscriptions.opml").write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.1"><head/><body>
    <outline text="News" title="News">
        <outline text="Folder Feed" title="Folder Feed" type="rss" xmlUrl="https://f.example/feed"/>
    </outline>
    <outline text="Root Feed" title="Root Feed" type="rss" xmlUrl="https://r.example/feed"/>
</body></opml>
""",
            encoding="utf-8",
        )
        connection = sqlite3.connect(account / "FeedSettings.db")
        try:
            connection.executemany(
                "INSERT INTO feedSettings (feedURL, feedID, editedName) VALUES (?, ?, ?)",
                [
                    ("https://f.example/feed", "https://f.example/feed", "Folder Feed"),
                    ("https://r.example/feed", "https://r.example/feed", "Root Feed"),
                ],
            )
            connection.commit()
        finally:
            connection.close()

        add_article(
            account, "f1", "https://f.example/feed",
            published=1700000400, status=(0, 0, 1700000400),
        )
        add_article(
            account, "f2", "https://f.example/feed",
            published=1700000300, status=(1, 0, 1700000300),
        )
        add_article(
            account, "r1", "https://r.example/feed",
            published=1700000200, status=(0, 0, 1700000200),
        )

        result, payload, data = p1_call(binary, root, "list_feeds", None)
        totals = data["totals"]
        feeds = data["feeds"]
        folders = data["folders"]
        root_feed = next(
            (feed for feed in feeds if feed["feed_id"] == "https://r.example/feed"), None
        )
        folder_feed_sum = sum(folder["feed_count"] for folder in folders)
        folder_unread_sum = sum(folder["unread_count"] for folder in folders)
        passed = (
            result["result"].get("isError") is False
            and totals["feeds"] == 2
            and totals["unread"] == 2
            and len(folders) == 1
            and folders[0]["name"] == "News"
            and folders[0]["feed_count"] == 1
            and folders[0]["unread_count"] == 1
            and folder_feed_sum <= totals["feeds"]
            and totals["feeds"] - folder_feed_sum == 1
            and folder_unread_sum <= totals["unread"]
            and totals["unread"] - folder_unread_sum == 1
            and root_feed is not None
            and root_feed["folder"] is None
            and root_feed["article_count"] == 1
            and root_feed["unread_count"] == 1
        )
        record(
            "p0_root_level_feed",
            passed,
            f"totals={totals} folders={folders} "
            f"root_feed_folder={root_feed.get('folder') if root_feed else None} "
            f"folder_feed_sum={folder_feed_sum} folder_unread_sum={folder_unread_sum}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_p2_digest_empty_feed_id(binary: str) -> None:
    base, _ = make_temporary_root("nnw-mcp-p2-empty-feed-")
    try:
        root = base / "NetNewsWire"
        account = make_account(root)
        write_database(account / "DB.sqlite3", SCHEMA, None)
        write_database(account / "FeedSettings.db", SCHEMA, None)
        (account / "Subscriptions.opml").write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.1"><head/><body>
    <outline text="News" title="News">
        <outline text="Feed One" title="Feed One" type="rss" xmlUrl="https://f1.example/feed"/>
    </outline>
</body></opml>
""",
            encoding="utf-8",
        )
        connection = sqlite3.connect(account / "FeedSettings.db")
        try:
            connection.execute(
                "INSERT INTO feedSettings (feedURL, feedID, editedName) VALUES (?, ?, ?)",
                ("https://f1.example/feed", "https://f1.example/feed", "Feed One"),
            )
            connection.commit()
        finally:
            connection.close()

        now = time.time()
        add_article(
            account, "good1", "https://f1.example/feed",
            published=now - 100, status=(0, 0, now - 100),
        )
        add_article(
            account, "empty1", "",
            published=now - 200, status=(0, 0, now - 200),
        )
        add_article(
            account, "empty2", "",
            published=now - 300, status=(1, 0, now - 300),
        )

        result, payload, data = p1_call(binary, root, "unread_digest", {"days": 1})
        totals = data["totals"]
        feeds = data["feeds"]
        feed_sum = sum(feed["unread_in_window"] for feed in feeds)
        d1 = feed_sum + data["omitted_unread_in_window"] == totals["unread_in_window"]
        d19 = totals["unread_feeds"] == len(feeds) + data["omitted_feeds"]
        passed = (
            result["result"].get("isError") is False
            and totals["unread_total"] == 1
            and totals["unread_in_window"] == 1
            and totals["articles_in_window"] == 1
            and totals["unread_feeds"] == 1
            and len(feeds) == 1
            and feeds[0]["feed_id"] == "https://f1.example/feed"
            and d1
            and d19
        )
        record(
            "p2_digest_empty_feed_id",
            passed,
            f"totals={totals} feeds={len(feeds)} feed_sum={feed_sum} "
            f"omitted_unread={data['omitted_unread_in_window']} d1={d1} d19={d19}",
        )
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=default_binary())
    args = parser.parse_args()
    binary = args.binary

    case_override_missing(binary)
    case_only_other_account(binary)
    case_missing_file(binary)
    case_zero_byte_database(binary)
    case_non_database(binary)
    case_unreadable_database(binary)
    case_schema(binary, "schema_missing_column", mutate_missing_column)
    case_schema(binary, "schema_not_fts4", mutate_not_fts4)
    case_schema(binary, "schema_no_trigger", mutate_no_trigger)
    case_opml(binary, "opml_empty", b"")
    case_opml(binary, "opml_invalid_xml", b"<opml><body><outline></body></opml>")
    case_opml(binary, "opml_missing_body", b'<?xml version="1.0"?><opml version="1.1"><head/></opml>')
    case_opml(binary, "opml_unreadable", None, unreadable=True)
    case_exit_code_priority(binary)
    case_mixed_accounts_and_64kib(binary)
    case_journal(binary)
    case_feed_url_null_and_empty(binary)
    case_p1_content_text_fallback(binary)
    case_p1_statuses_missing(binary)
    case_p1_get_article_96kib(binary)
    case_p1_orphan_feed_id(binary)
    case_p1_author_shapes(binary)
    case_p0_root_level_feed(binary)
    case_p2_digest_empty_feed_id(binary)

    failed = [name for name, passed, _ in results if not passed]
    print(f"fixture_cases={len(results)} failed={len(failed)}")
    if failed:
        print("FAILED_CASES:", failed)
        return 1
    print("fixtures_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
