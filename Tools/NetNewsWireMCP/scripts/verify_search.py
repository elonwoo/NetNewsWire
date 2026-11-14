#!/usr/bin/env python3
"""Compares search_articles with direct FTS/LIKE queries on the live data root.

Mirrors the contract's classification exactly:
  * ASCII alphanumeric runs -> FTS4 MATCH with each run quoted (implicit AND)
  * CJK runs                -> LIKE '%run%' ESCAPE '\\' on search.title/body
  * mixed queries           -> intersection of the two sets
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import time
from pathlib import Path
from urllib.parse import quote

from mcp_client import MCPClient, default_binary, tool_text

DEFAULT_ROOT = Path.home() / "Library/Application Support/NetNewsWire"
SEARCH_LIMIT = 32 * 1024
CJK_PATTERN = re.compile(r"[㐀-䶿一-鿿豈-﫿]{2,}")
ASCII_WORD = re.compile(r"[A-Za-z0-9]{3,}")
OPERATORS = {"and", "or", "not", "near"}


def open_read_only(path: Path) -> sqlite3.Connection:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


def classify(query: str) -> tuple[list[str], list[str]]:
    ascii_terms: list[str] = []
    cjk_terms: list[str] = []
    for token in query.split():
        for run in re.findall(
            r"[A-Za-z0-9]+|[㐀-䶿一-鿿豈-﫿]+", token
        ):
            if run[0].isascii():
                if len(ascii_terms) < 20:
                    ascii_terms.append(run)
            else:
                cjk_terms.append(run)
    return ascii_terms, cjk_terms


def escape_like(term: str) -> str:
    out = ["%"]
    for character in term:
        if character in ("\\", "%", "_"):
            out.append("\\")
        out.append(character)
    out.append("%")
    return "".join(out)


def fts_count(database: sqlite3.Connection, ascii_terms: list[str]) -> int:
    match = " ".join(f'"{term}"' for term in ascii_terms)
    row = database.execute(
        "SELECT count(*) FROM articles AS a "
        "WHERE a.searchRowID IN (SELECT docid FROM search WHERE search MATCH ?)",
        (match,),
    ).fetchone()
    return int(row[0])


def like_count(database: sqlite3.Connection, cjk_terms: list[str]) -> int:
    conditions = " AND ".join(
        ["(f.title LIKE ? ESCAPE '\\' OR f.body LIKE ? ESCAPE '\\')"] * len(cjk_terms)
    )
    params: list[str] = []
    for term in cjk_terms:
        pattern = escape_like(term)
        params.extend([pattern, pattern])
    row = database.execute(
        "SELECT count(*) FROM articles AS a "
        "LEFT JOIN search AS f ON f.rowid = a.searchRowID "
        f"WHERE {conditions}",
        params,
    ).fetchone()
    return int(row[0])


def hybrid_count(
    database: sqlite3.Connection, ascii_terms: list[str], cjk_terms: list[str]
) -> int:
    match = " ".join(f'"{term}"' for term in ascii_terms)
    conditions = " AND ".join(
        ["(f.title LIKE ? ESCAPE '\\' OR f.body LIKE ? ESCAPE '\\')"] * len(cjk_terms)
    )
    params: list[str] = []
    for term in cjk_terms:
        pattern = escape_like(term)
        params.extend([pattern, pattern])
    row = database.execute(
        "SELECT count(*) FROM articles AS a "
        "LEFT JOIN search AS f ON f.rowid = a.searchRowID "
        "WHERE a.searchRowID IN (SELECT docid FROM search WHERE search MATCH ?) "
        f"AND {conditions}",
        [match, *params],
    ).fetchone()
    return int(row[0])


def pick_ascii_term(database: sqlite3.Connection) -> str | None:
    candidates: list[str] = []
    for title, body in database.execute(
        "SELECT title, body FROM search WHERE body IS NOT NULL "
        "ORDER BY docid DESC LIMIT 300"
    ):
        for match in ASCII_WORD.findall(body or ""):
            word = match.lower()
            if word not in OPERATORS and word not in candidates:
                candidates.append(word)
    for word in candidates:
        if fts_count(database, [word]) > 0:
            return word
    return None


def pick_cjk_term(database: sqlite3.Connection) -> str | None:
    for title, body in database.execute(
        "SELECT title, body FROM search ORDER BY docid DESC LIMIT 300"
    ):
        for text in (title or "", body or ""):
            match = CJK_PATTERN.search(text)
            if match:
                return match.group(0)[:2]
    return None


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

        feeds_call = client.call_tool("list_feeds")
        feeds_data = json.loads(tool_text(feeds_call))
        data_root = Path(feeds_data["data_root"])
        print("data_root=", data_root)
        database = open_read_only(data_root / "Accounts/OnMyMac/DB.sqlite3")
        try:
            ascii_term = pick_ascii_term(database)
            cjk_term = pick_cjk_term(database)
            print("ascii_term=", ascii_term, "cjk_term=", cjk_term)
            if not ascii_term or not cjk_term:
                record("term_selection", False, "真实数据中找不到可用的 ASCII/CJK 词项")
                raise SystemExit(1)

            cases = [
                ("terms", ascii_term, None, fts_count(database, [ascii_term])),
                ("substring", cjk_term, None, like_count(database, [cjk_term])),
                (
                    "hybrid",
                    f"{ascii_term} {cjk_term}",
                    None,
                    hybrid_count(database, [ascii_term], [cjk_term]),
                ),
            ]

            date_by_id = {
                article_id: date
                for article_id, date in database.execute(
                    "SELECT articleID, datePublished FROM articles"
                )
            }

            for mode, query, _, direct in cases:
                ascii_terms, cjk_terms = classify(query)
                call = client.call_tool("search_articles", {"query": query})
                payload = tool_text(call)
                if call["result"].get("isError"):
                    record(
                        f"search.{mode}",
                        False,
                        f"isError payload={payload[:160]!r}",
                    )
                    continue
                data = json.loads(payload)
                returned = data["returned"]
                articles = data["articles"]
                total = data["total_matched"]
                expected_mode = (
                    "terms"
                    if not cjk_terms
                    else ("substring" if not ascii_terms else "hybrid")
                )
                limit_ok = returned == len(articles) and returned + data["omitted"] == min(
                    total, 20
                )
                snippet_ok = all(len(item["snippet"]) <= 400 for item in articles)
                ordered = [
                    (date_by_id.get(item["article_id"]), item["article_id"])
                    for item in articles
                ]
                sort_ok = True
                seen_null = False
                previous = None
                for date, _ in ordered:
                    if date is None:
                        seen_null = True
                    else:
                        if seen_null or (previous is not None and date > previous):
                            sort_ok = False
                        previous = date
                bytes_ok = len(payload.encode("utf-8")) <= SEARCH_LIMIT

                # total_matched must not depend on limit.
                limited_call = client.call_tool(
                    "search_articles", {"query": query, "limit": 1}
                )
                limited_data = json.loads(tool_text(limited_call))
                limit_independent = limited_data["total_matched"] == total

                passed = (
                    data["mode_used"] == expected_mode
                    and total == direct
                    and data["mode_used"] == mode
                    and limit_ok
                    and snippet_ok
                    and sort_ok
                    and bytes_ok
                    and limit_independent
                )
                record(
                    f"search.{mode}",
                    passed,
                    f"query={query!r} tool={total} direct={direct} equal={total == direct} "
                    f"mode_tool={data['mode_used']} mode_expected={mode} "
                    f"returned={returned} omitted={data['omitted']} "
                    f"limit_invariant={limit_ok} limit_independent={limit_independent} "
                    f"snippets_ok={snippet_ok} sort_ok={sort_ok} "
                    f"bytes={len(payload.encode('utf-8'))} bytes_ok={bytes_ok}",
                )

            empty = client.call_tool("search_articles", {"query": "!!!"})
            empty_text = tool_text(empty)
            passed = (
                empty["result"].get("isError") is True
                and "词项" in empty_text
                and "mode_used" not in empty_text
            )
            record(
                "search.empty_query",
                passed,
                f"isError={empty['result'].get('isError')} message={empty_text[:80]!r}",
            )

            # Latency of a LIKE query: p95 < 500 ms, single call < 2500 ms.
            timings: list[float] = []
            for _ in range(20):
                start = time.perf_counter()
                client.call_tool("search_articles", {"query": cjk_term})
                timings.append((time.perf_counter() - start) * 1000)
            timings.sort()
            p95 = timings[int(len(timings) * 0.95) - 1]
            maximum = timings[-1]
            record(
                "search.latency",
                p95 < 500 and maximum < 2500,
                f"query={cjk_term!r} samples={len(timings)} "
                f"p95_ms={p95:.1f} max_ms={maximum:.1f} "
                f"min_ms={timings[0]:.1f}",
            )
        finally:
            database.close()
    finally:
        stderr = client.close()

    print("stderr_first_line=", stderr.splitlines()[0] if stderr.splitlines() else "")
    if failures:
        print("FAILURES:", failures)
        return 1
    print("search_verification=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
