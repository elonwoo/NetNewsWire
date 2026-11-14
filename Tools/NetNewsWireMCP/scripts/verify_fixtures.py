#!/usr/bin/env python3
"""Runs the P0 fixture acceptance cases against the built binary."""

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

    failed = [name for name, passed, _ in results if not passed]
    print(f"fixture_cases={len(results)} failed={len(failed)}")
    if failed:
        print("FAILED_CASES:", failed)
        return 1
    print("fixtures_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
