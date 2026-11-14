import Foundation
import MCP
import XCTest

@testable import NetNewsWireMCPCore

final class PaginationAndQueryTests: XCTestCase {
    // MARK: - Helpers

    private func decode(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw TestError(message: "响应不是 JSON object")
        }
        return dictionary
    }

    private func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    @discardableResult
    private func insertArticle(
        _ root: TestRoot,
        id: String,
        feedID: String = "https://a.example/feed",
        datePublished: Double?,
        searchRowID: Int? = nil
    ) throws -> String {
        let dateLiteral = datePublished.map { String($0) } ?? "NULL"
        let searchLiteral = searchRowID.map { String($0) } ?? "NULL"
        let writer = try SQLiteWriter(path: root.databaseURL.path)
        try writer.exec(
            """
            INSERT INTO articles
                (articleID, feedID, uniqueID, title, datePublished, searchRowID, contentText)
            VALUES (\(literal(id)), \(literal(feedID)), \(literal(id)), \(literal(id)),
                    \(dateLiteral), \(searchLiteral), '');
            """)
        return id
    }

    private func insertSearchRows(_ root: TestRoot, rows: [(Int, String, String)]) throws {
        let writer = try SQLiteWriter(path: root.databaseURL.path)
        var index = 0
        while index < rows.count {
            let upper = min(index + 50, rows.count)
            let chunk = rows[index..<upper].map {
                "(\($0.0), \(literal($0.1)), \(literal($0.2)))"
            }
            try writer.exec(
                "INSERT INTO search (docid, title, body) VALUES \(chunk.joined(separator: ","));")
            index = upper
        }
    }

    private func pageIDs(_ object: [String: Any]) -> [String] {
        ((object["articles"] as? [[String: Any]]) ?? []).compactMap { $0["article_id"] as? String }
    }

    /// Walks `list_articles` to exhaustion. Returns the collected ids, the page
    /// count, and the sequence of `total_matched` values seen.
    private func collectListPages(
        context: ServerContext, arguments: [String: Value], limit: Int
    ) throws -> (ids: [String], pages: Int, totals: [Int]) {
        var ids: [String] = []
        var pages = 0
        var totals: [Int] = []
        var cursor: String?
        while true {
            var pageArguments = arguments
            pageArguments["limit"] = .int(limit)
            if let cursor { pageArguments["after"] = .string(cursor) }
            let object = try decode(
                try ListArticlesTool.run(arguments: pageArguments, context: context))
            let page = pageIDs(object)
            XCTAssertEqual(object["returned"] as? Int, page.count)
            totals.append(object["total_matched"] as? Int ?? -1)
            ids.append(contentsOf: page)
            pages += 1
            guard let next = object["next_cursor"] as? String else { break }
            cursor = next
            XCTAssertLessThan(pages, 1000, "游标遍历未终止")
        }
        return (ids, pages, totals)
    }

    private func collectSearchPages(
        context: ServerContext, query: String, limit: Int
    ) throws -> (ids: [String], pages: Int, totals: [Int]) {
        var ids: [String] = []
        var pages = 0
        var totals: [Int] = []
        var cursor: String?
        while true {
            var arguments: [String: Value] = ["query": .string(query), "limit": .int(limit)]
            if let cursor { arguments["after"] = .string(cursor) }
            let object = try decode(
                try SearchArticlesTool.run(arguments: arguments, context: context))
            let page = pageIDs(object)
            totals.append(object["total_matched"] as? Int ?? -1)
            ids.append(contentsOf: page)
            pages += 1
            guard let next = object["next_cursor"] as? String else { break }
            cursor = next
            XCTAssertLessThan(pages, 1000, "游标遍历未终止")
        }
        return (ids, pages, totals)
    }

    // MARK: - list_articles cursors

    func testListArticlesCursorCrossesNullDateBoundary() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        // The seed has five dated articles and one null-dated article (a3).
        let walked = try collectListPages(context: context, arguments: [:], limit: 2)

        let expected = ["b1", "a1", "c1", "b2", "a2", "a3"]
        XCTAssertEqual(walked.ids, expected)
        XCTAssertEqual(Set(walked.ids).count, walked.ids.count, "游标遍历出现重复")
        XCTAssertEqual(walked.pages, 3)
        XCTAssertEqual(walked.totals, [6, 6, 6])

        // The final page contains the null-dated article, proving the cursor
        // crossed the null boundary instead of stopping at the dated rows.
        XCTAssertEqual(walked.ids.last, "a3")
    }

    func testListArticlesPaginationIsCompleteOverOneHundredRows() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES ('https://a.example/feed', 'https://a.example/feed', 'Alpha');
            """)

        let total = 250
        for index in 0..<total {
            try insertArticle(
                root, id: String(format: "m%03d", index),
                datePublished: 1_700_000_000 + Double(index))
        }
        let context = try root.prepare()

        let walked = try collectListPages(context: context, arguments: [:], limit: 40)
        XCTAssertEqual(walked.ids.count, total)
        XCTAssertEqual(Set(walked.ids).count, total, "遍历出现重复")
        XCTAssertEqual(walked.ids.count, walked.ids.count)
        XCTAssertEqual(walked.pages, 7)
        XCTAssertEqual(walked.totals, Array(repeating: total, count: 7))

        let expected = (0..<total).reversed().map { String(format: "m%03d", $0) }
        XCTAssertEqual(walked.ids, expected)
    }

    func testCursorRejectedWhenFiltersChange() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertSearchRows(root, rows: [
            (1, "A one", "Body one"),
            (2, "A two", "Body two"),
            (3, "", "Body three"),
            (4, "B one", "Body four"),
            (5, "B two", "Body five"),
            (6, "C one", "Body six"),
        ])

        let first = try decode(
            try ListArticlesTool.run(
                arguments: ["feed_id": .string("https://a.example/feed"), "limit": .int(1)],
                context: context))
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        XCTAssertEqual(first["total_matched"] as? Int, 3)

        let mismatches: [[String: Value]] = [
            ["feed_id": .string("https://b.example/feed")],
            ["unread_only": .bool(true)],
            ["since": .string("2023-11-14T22:16:40Z")],
            [:],
        ]
        for arguments in mismatches {
            XCTAssertThrowsError(
                try ListArticlesTool.run(
                    arguments: arguments.merging(["after": .string(cursor)]) { $1 },
                    context: context)
            ) { error in
                XCTAssertTrue(
                    (error as? ToolError)?.message.contains("不匹配") == true,
                    "实际错误：\(error)")
            }
        }

        XCTAssertThrowsError(
            try ListArticlesTool.run(
                arguments: ["after": .string("not-base64!!")], context: context)
        ) { error in
            XCTAssertTrue((error as? ToolError)?.message.contains("格式无效") == true)
        }

        // A cursor from `search_articles` is not valid for `list_articles`.
        let searchPage = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("body"), "limit": .int(1)], context: context))
        let searchCursor = try XCTUnwrap(searchPage["next_cursor"] as? String)
        XCTAssertThrowsError(
            try ListArticlesTool.run(
                arguments: ["after": .string(searchCursor)], context: context)
        ) { error in
            XCTAssertTrue((error as? ToolError)?.message.contains("不匹配") == true)
        }
    }

    func testListArticlesSinceIsInclusiveAndExcludesNullDates() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()

        let object = try decode(
            try ListArticlesTool.run(
                arguments: ["since": .string("2023-11-14T22:16:40Z"), "limit": .int(100)],
                context: context))
        XCTAssertEqual(object["total_matched"] as? Int, 2)
        XCTAssertEqual(pageIDs(object), ["b1", "a1"])

        let nullDatesExcluded = try decode(
            try ListArticlesTool.run(
                arguments: ["since": .string("2023-11-14T00:00:00Z"), "limit": .int(100)],
                context: context))
        XCTAssertEqual(nullDatesExcluded["total_matched"] as? Int, 5)

        XCTAssertThrowsError(
            try ListArticlesTool.run(
                arguments: ["since": .string("not-a-date")], context: context)
        ) { error in
            XCTAssertTrue((error as? ToolError)?.message.contains("ISO 8601") == true)
        }
    }

    // MARK: - search_articles cursors

    func testSearchArticlesCursorCrossesNullDateBoundary() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertSearchRows(root, rows: [
            (1, "A one", "First alpha excerpt line.\nSecond line."),
            (2, "A two", "Body two"),
            (3, "", "Body three"),
            (4, "B one", "Body four"),
            (5, "B two", "Body five"),
            (6, "C one", "Body six"),
        ])

        let walked = try collectSearchPages(context: context, query: "body", limit: 2)
        XCTAssertEqual(walked.ids, ["b1", "c1", "b2", "a2", "a3"])
        XCTAssertEqual(Set(walked.ids).count, walked.ids.count)
        XCTAssertEqual(walked.pages, 3)
        XCTAssertEqual(walked.totals, [5, 5, 5])
        XCTAssertEqual(walked.ids.last, "a3")
    }

    func testSearchArticlesPaginationIsComplete() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES ('https://a.example/feed', 'https://a.example/feed', 'Alpha');
            """)

        let total = 120
        var searchRows: [(Int, String, String)] = []
        for index in 0..<total {
            searchRows.append((index + 1, "Title \(index)", "needle body \(index)"))
            try insertArticle(
                root, id: String(format: "s%03d", index),
                datePublished: 1_700_000_000 + Double(index), searchRowID: index + 1)
        }
        try insertSearchRows(root, rows: searchRows)
        let context = try root.prepare()

        let walked = try collectSearchPages(context: context, query: "needle", limit: 25)
        XCTAssertEqual(walked.ids.count, total)
        XCTAssertEqual(Set(walked.ids).count, total)
        XCTAssertEqual(walked.pages, 5)
        XCTAssertEqual(walked.totals, Array(repeating: total, count: 5))
        XCTAssertEqual(walked.ids.first, "s119")

        let firstPage = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("needle"), "limit": .int(5)], context: context))
        let cursor = try XCTUnwrap(firstPage["next_cursor"] as? String)
        XCTAssertThrowsError(
            try SearchArticlesTool.run(
                arguments: ["query": .string("other"), "after": .string(cursor)],
                context: context)
        ) { error in
            XCTAssertTrue((error as? ToolError)?.message.contains("不匹配") == true)
        }
    }

    // MARK: - query

    func testQueryReturnsColumnsRowsAndTypedValues() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()

        let count = try decode(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT count(*) AS n FROM articles")],
                context: context))
        XCTAssertEqual(count["columns"] as? [String], ["n"])
        XCTAssertEqual(count["row_count"] as? Int, 1)
        XCTAssertEqual(count["truncated"] as? Bool, false)
        XCTAssertTrue(count["truncated_reason"] is NSNull)
        XCTAssertEqual((count["rows"] as? [[Any]])?.first?.first as? Int, 6)
        XCTAssertNotNil(count["elapsed_ms"] as? Int)

        let attached = try decode(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT count(*) FROM fs.feedSettings")],
                context: context))
        XCTAssertEqual((attached["rows"] as? [[Any]])?.first?.first as? Int, 4)

        let typed = try decode(
            try QueryTool.run(
                arguments: [
                    "sql": .string(
                        """
                        SELECT 9007199254740993 AS big, 1.5 AS r, NULL AS z,
                               x'00ff' AS b, 'txt' AS t
                        """)
                ], context: context))
        XCTAssertEqual(
            typed["columns"] as? [String], ["big", "r", "z", "b", "t"])
        let row = try XCTUnwrap((typed["rows"] as? [[Any]])?.first)
        XCTAssertEqual(row[0] as? String, "9007199254740993")
        XCTAssertEqual(row[1] as? Double, 1.5)
        XCTAssertTrue(row[2] is NSNull)
        XCTAssertEqual(row[3] as? String, "00ff")
        XCTAssertEqual(row[4] as? String, "txt")

        // Column names are exactly the ones authored, aliases included.
        let aliased = try decode(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT articleID AS id FROM articles LIMIT 1")],
                context: context))
        XCTAssertEqual(aliased["columns"] as? [String], ["id"])
    }

    func testQueryRejectsMultipleStatementsAndNonSelect() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()

        XCTAssertThrowsError(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT 1 AS a; SELECT 2 AS b")], context: context)
        ) { error in
            XCTAssertTrue(
                (error as? ToolError)?.message.contains("multiple_statements") == true,
                "实际错误：\(error)")
        }

        // A single statement with a trailing semicolon is fine.
        let trailing = try decode(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT 1 AS a;")], context: context))
        XCTAssertEqual(trailing["row_count"] as? Int, 1)

        // A semicolon inside a string literal is not a statement separator.
        let quoted = try decode(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT ';' AS s")], context: context))
        XCTAssertEqual((quoted["rows"] as? [[Any]])?.first?.first as? String, ";")

        for sql in [
            "PRAGMA table_info(articles)",
            "ATTACH DATABASE ':memory:' AS extra",
            "UPDATE articles SET title = 'x'",
            "EXPLAIN SELECT 1",
        ] {
            XCTAssertThrowsError(
                try QueryTool.run(arguments: ["sql": .string(sql)], context: context)
            ) { error in
                XCTAssertTrue(
                    (error as? ToolError)?.message.contains("not_select") == true,
                    "\(sql) 实际错误：\(error)")
            }
        }

        // A `WITH` body that writes reaches the read-only connection and fails
        // at execution time, not by static rejection.
        XCTAssertThrowsError(
            try QueryTool.run(
                arguments: [
                    "sql": .string(
                        "WITH c AS (SELECT 'x' AS id) INSERT INTO statuses (articleID) "
                            + "SELECT id FROM c")
                ], context: context)
        ) { error in
            XCTAssertTrue(
                (error as? ToolError)?.message.contains("execution_error") == true,
                "实际错误：\(error)")
        }
    }

    func testQueryEnforcesRowLimit() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()
        for index in 0..<250 {
            try insertArticle(
                root, id: String(format: "q%03d", index),
                datePublished: 1_700_000_000 + Double(index))
        }
        let context = try root.prepare()

        let capped = try decode(
            try QueryTool.run(
                arguments: [
                    "sql": .string("SELECT articleID FROM articles"), "limit": .int(10),
                ], context: context))
        XCTAssertEqual(capped["row_count"] as? Int, 10)
        XCTAssertEqual((capped["rows"] as? [[Any]])?.count, 10)
        XCTAssertEqual(capped["truncated"] as? Bool, true)
        XCTAssertEqual(capped["truncated_reason"] as? String, "row_limit")

        let innerLimit = try decode(
            try QueryTool.run(
                arguments: [
                    "sql": .string("SELECT articleID FROM articles LIMIT 5"),
                    "limit": .int(50),
                ], context: context))
        XCTAssertEqual(innerLimit["row_count"] as? Int, 5)
        XCTAssertEqual(innerLimit["truncated"] as? Bool, false)
        XCTAssertTrue(innerLimit["truncated_reason"] is NSNull)
    }

    func testQueryDropsRowsAtByteLimit() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()
        let body = String(repeating: "a", count: 1000)
        var rows: [(Int, String, String)] = []
        for index in 0..<200 {
            rows.append((index + 1, "Row \(index)", body))
            try insertArticle(
                root, id: String(format: "b%03d", index),
                datePublished: 1_700_000_000 + Double(index), searchRowID: index + 1)
        }
        try insertSearchRows(root, rows: rows)
        let context = try root.prepare()

        let json = try QueryTool.run(
            arguments: ["sql": .string("SELECT body FROM search"), "limit": .int(100)],
            context: context)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.queryBytes)

        let object = try decode(json)
        let returned = try XCTUnwrap(object["rows"] as? [[Any]])
        XCTAssertEqual(object["row_count"] as? Int, returned.count)
        XCTAssertLessThan(returned.count, 100)
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertEqual(object["truncated_reason"] as? String, "byte_limit")
    }

    func testQueryFirstRowTooLargeIsAnError() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()
        try insertSearchRows(
            root, rows: [(1, "Huge", String(repeating: "a", count: 70_000))])
        let context = try root.prepare()

        XCTAssertThrowsError(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT body FROM search WHERE docid = 1")],
                context: context)
        ) { error in
            let message = (error as? ToolError)?.message ?? ""
            XCTAssertTrue(message.contains("single_row_too_large"), "实际错误：\(message)")
            XCTAssertTrue(message.contains("字节"), "实际错误：\(message)")
        }
    }

    func testQueryRejectsInvalidLimitAndMissingSQL() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        XCTAssertThrowsError(try QueryTool.run(arguments: nil, context: context))
        for limit in [0, 101] {
            XCTAssertThrowsError(
                try QueryTool.run(
                    arguments: ["sql": .string("SELECT 1"), "limit": .int(limit)],
                    context: context))
        }
        XCTAssertThrowsError(
            try QueryTool.run(
                arguments: ["sql": .string("SELECT 1"), "extra": .int(1)], context: context))
    }

    func testQueryOpensExactlyOneConnection() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        ReadOnlyDatabase.connectionCounter.reset()
        _ = try QueryTool.run(
            arguments: ["sql": .string("SELECT count(*) FROM articles")], context: context)
        XCTAssertEqual(ReadOnlyDatabase.connectionCounter.count, 1)
    }
}
