import Foundation
import XCTest

@testable import NetNewsWireMCPCore

final class ToolsTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func decode(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw TestError(message: "响应不是 JSON object")
        }
        return dictionary
    }

    func testToolCatalogHasFiveTools() {
        XCTAssertEqual(ToolCatalog.serverTools.count, 5)
        XCTAssertEqual(
            ToolCatalog.serverTools.map(\.name),
            ["list_feeds", "list_articles", "get_article", "search_articles", "unread_digest"])
        for tool in ToolCatalog.serverTools {
            XCTAssertEqual(tool.annotations.readOnlyHint, true)
            XCTAssertEqual(tool.annotations.destructiveHint, false)
            XCTAssertEqual(tool.annotations.idempotentHint, true)
            XCTAssertEqual(tool.annotations.openWorldHint, false)
        }
    }

    func testStandardListFeedsValues() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try root.setDatabaseMtime(fixedNow.addingTimeInterval(-3600))

        let json = try ListFeedsTool.run(context: context, now: fixedNow)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.listFeedsBytes)

        let object = try decode(json)
        XCTAssertEqual(object["account"] as? String, "OnMyMac")
        XCTAssertEqual(object["data_root"] as? String, root.root.path)
        XCTAssertEqual(object["data_root_mtime"] as? String, "2027-01-15T07:00:00Z")
        XCTAssertEqual(object["data_age_seconds"] as? Int, 3600)
        XCTAssertEqual(object["generated_at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(object["ambiguous_data_roots"] as? Bool, false)
        XCTAssertEqual(object["truncated"] as? Bool, false)
        XCTAssertEqual(object["omitted"] as? Int, 0)
        XCTAssertEqual(object["unsupported_accounts"] as? [String], [])
        XCTAssertEqual(object["warnings"] as? [String], [])

        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        XCTAssertEqual(totals["feeds"] as? Int, 4)
        XCTAssertEqual(totals["folders"] as? Int, 3)
        XCTAssertEqual(totals["articles"] as? Int, 6)
        XCTAssertEqual(totals["unread"] as? Int, 3)
        XCTAssertEqual(totals["starred"] as? Int, 2)

        let folders = try XCTUnwrap(object["folders"] as? [[String: Any]])
        XCTAssertEqual(folders.map { $0["name"] as? String }, ["Empty", "News", "Tech"])
        XCTAssertEqual(folders.map { $0["feed_count"] as? Int }, [0, 2, 2])
        XCTAssertEqual(folders.map { $0["unread_count"] as? Int }, [0, 2, 1])
        XCTAssertEqual(folders.reduce(0) { $0 + ($1["feed_count"] as? Int ?? 0) }, 4)
        XCTAssertEqual(folders.reduce(0) { $0 + ($1["unread_count"] as? Int ?? 0) }, 3)

        let feeds = try XCTUnwrap(object["feeds"] as? [[String: Any]])
        XCTAssertEqual(feeds.count, 4)
        XCTAssertEqual(
            feeds.map { $0["feed_id"] as? String },
            [
                "https://a.example/feed",
                "https://c.example/feed",
                "https://b.example/feed",
                "https://d.example/feed",
            ])

        let alpha = feeds[0]
        XCTAssertEqual(alpha["title"] as? String, "Alpha Edited")
        XCTAssertEqual(alpha["folder"] as? String, "News")
        XCTAssertEqual(alpha["home_page_url"] as? String, "https://a.example/")
        XCTAssertEqual(alpha["article_count"] as? Int, 3)
        XCTAssertEqual(alpha["unread_count"] as? Int, 2)
        XCTAssertEqual(alpha["latest_published_at"] as? String, "2023-11-14T22:16:40Z")

        let cee = feeds[1]
        XCTAssertEqual(cee["title"] as? String, "Cee Title")
        XCTAssertEqual(cee["folder"] as? String, "Tech")
        XCTAssertEqual(cee["home_page_url"] as? String, nil)
        XCTAssertEqual(cee["article_count"] as? Int, 1)
        XCTAssertEqual(cee["unread_count"] as? Int, 1)
        XCTAssertEqual(cee["latest_published_at"] as? String, "2023-11-14T22:15:50Z")

        let bee = feeds[2]
        XCTAssertEqual(bee["title"] as? String, "Bee Text")
        XCTAssertEqual(bee["home_page_url"] as? String, "https://opml.example/b")
        XCTAssertEqual(bee["latest_published_at"] as? String, "2023-11-14T22:18:20Z")

        let delta = feeds[3]
        XCTAssertEqual(delta["title"] as? String, "Delta")
        XCTAssertEqual(delta["folder"] as? String, "Tech")
        XCTAssertEqual(delta["home_page_url"] as? String, "https://d.example/")
        XCTAssertEqual(delta["article_count"] as? Int, 0)
        XCTAssertEqual(delta["unread_count"] as? Int, 0)
        XCTAssertEqual(delta["latest_published_at"] as? String, nil)

        let candidates = try XCTUnwrap(object["data_root_candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0]["path"] as? String, root.root.path)
        XCTAssertEqual(candidates[0]["exists"] as? Bool, true)
        XCTAssertEqual(candidates[0]["selected"] as? Bool, true)
    }

    func testNullableFieldsEncodeExplicitNull() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeOPML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="1.1"><head/><body>
                <outline text="Root Feed" title="Root Feed" type="rss" xmlUrl="https://r.example/feed"/>
            </body></opml>
            """
        )
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName, homePageURL)
            VALUES ('https://r.example/feed', 'https://r.example/feed', NULL, NULL);
            """
        )
        let articleWriter = try SQLiteWriter(path: root.databaseURL.path)
        try articleWriter.exec(
            """
            INSERT INTO articles (articleID, feedID, uniqueID, title, datePublished, searchRowID)
            VALUES ('root-1', 'https://r.example/feed', 'root-1', 'Root article', NULL, 1);
            """
        )

        let context = try root.prepare()
        let object = try decode(try ListFeedsTool.run(context: context, now: fixedNow))
        let feeds = try XCTUnwrap(object["feeds"] as? [[String: Any]])
        XCTAssertEqual(feeds.count, 1)
        let feed = feeds[0]

        for key in ["folder", "home_page_url", "latest_published_at"] {
            XCTAssertTrue(feed.keys.contains(key), "缺少键 \(key)")
            XCTAssertTrue(feed[key] is NSNull, "\(key) 应为显式 null")
        }
        XCTAssertEqual(feed["feed_id"] as? String, "https://r.example/feed")
        XCTAssertEqual(feed["title"] as? String, "Root Feed")
        XCTAssertEqual(feed["article_count"] as? Int, 1)
        XCTAssertEqual(feed["unread_count"] as? Int, 1)

        let folders = try XCTUnwrap(object["folders"] as? [[String: Any]])
        XCTAssertTrue(folders.isEmpty, "根级 feed 不应产生文件夹或未分组合成桶")

        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        let totalFeeds = try XCTUnwrap(totals["feeds"] as? Int)
        let totalUnread = try XCTUnwrap(totals["unread"] as? Int)
        let folderFeedSum = folders.reduce(0) { $0 + ($1["feed_count"] as? Int ?? 0) }
        let folderUnreadSum = folders.reduce(0) { $0 + ($1["unread_count"] as? Int ?? 0) }

        XCTAssertEqual(totalFeeds, 1)
        XCTAssertEqual(totalUnread, 1)
        XCTAssertLessThanOrEqual(folderFeedSum, totalFeeds)
        XCTAssertEqual(totalFeeds - folderFeedSum, feeds.count)
        XCTAssertLessThanOrEqual(folderUnreadSum, totalUnread)
        XCTAssertEqual(
            totalUnread - folderUnreadSum, try XCTUnwrap(feed["unread_count"] as? Int))
    }

    func testNullAndEmptyFeedURLRowsAreNotCounted() throws {
        let root = try TestRoot()
        try root.writeStandardDatabases()
        try root.writeStandardOPML()

        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES (NULL, '', 'Null URL');
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES ('', '', 'Empty URL');
            """
        )

        let context = try root.prepare()
        let object = try decode(try ListFeedsTool.run(context: context, now: fixedNow))
        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        XCTAssertEqual(totals["feeds"] as? Int, 4)

        let feeds = try XCTUnwrap(object["feeds"] as? [[String: Any]])
        XCTAssertEqual(feeds.count, 4)
        XCTAssertFalse(feeds.contains { ($0["feed_id"] as? String)?.isEmpty != false })
        XCTAssertFalse(feeds.contains { ($0["title"] as? String) == "Null URL" })
        XCTAssertFalse(feeds.contains { ($0["title"] as? String) == "Empty URL" })
    }

    func testCandidateWithMissingDatabaseEncodesExplicitNullMtime() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nnw-mcp-nullcandidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let activeRoot = home.appendingPathComponent(
            DataRootConstants.activeRelativePath, isDirectory: true)
        let active = try TestRoot(root: activeRoot)
        try active.writeStandardDatabases()
        try active.writeStandardOPML()

        let legacyRoot = home.appendingPathComponent(
            DataRootConstants.legacyContainerRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyRoot.appendingPathComponent("Accounts/OnMyMac", isDirectory: true),
            withIntermediateDirectories: true)

        let context = try Startup.prepare(environment: [:], homeDirectory: home.path)
        let object = try decode(try ListFeedsTool.run(context: context, now: fixedNow))
        let candidates = try XCTUnwrap(object["data_root_candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 2)

        let legacyPath = legacyRoot.standardizedFileURL.path
        let legacy = try XCTUnwrap(candidates.first { $0["path"] as? String == legacyPath })
        XCTAssertTrue(legacy.keys.contains("db_mtime"), "缺少 db_mtime 键")
        XCTAssertTrue(legacy["db_mtime"] is NSNull, "db_mtime 应为显式 null")
        XCTAssertEqual(legacy["exists"] as? Bool, true)
        XCTAssertEqual(legacy["selected"] as? Bool, false)
        XCTAssertEqual(object["ambiguous_data_roots"] as? Bool, false)
    }

    func testListFeedsOpensExactlyOneConnection() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()

        ReadOnlyDatabase.connectionCounter.reset()
        _ = try ListFeedsTool.run(context: context, now: fixedNow)
        XCTAssertEqual(ReadOnlyDatabase.connectionCounter.count, 1)
    }

    func testDataAgeWarning() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try root.setDatabaseMtime(fixedNow.addingTimeInterval(-90_000))

        let object = try decode(try ListFeedsTool.run(context: context, now: fixedNow))
        XCTAssertEqual(object["data_age_seconds"] as? Int, 90_000)
        let warnings = try XCTUnwrap(object["warnings"] as? [String])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("86400"))
    }

    func testAmbiguousRootWarningWithTwoCandidates() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nnw-mcp-ambiguous-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let activeRoot = home.appendingPathComponent(
            DataRootConstants.activeRelativePath, isDirectory: true)
        let active = try TestRoot(root: activeRoot)
        try active.writeStandardDatabases()
        try active.writeStandardOPML()
        try active.setDatabaseMtime(Date(timeIntervalSince1970: 1_800_000_000))

        let legacyRoot = home.appendingPathComponent(
            DataRootConstants.legacyContainerRelativePath, isDirectory: true)
        let legacy = try TestRoot(root: legacyRoot)
        try legacy.writeStandardDatabases()
        try legacy.writeStandardOPML()
        try legacy.setDatabaseMtime(Date(timeIntervalSince1970: 1_800_000_100))

        let context = try Startup.prepare(environment: [:], homeDirectory: home.path)
        XCTAssertEqual(context.candidatePaths.count, 2)

        let object = try decode(try ListFeedsTool.run(context: context, now: fixedNow))
        XCTAssertEqual(object["ambiguous_data_roots"] as? Bool, true)
        let warnings = try XCTUnwrap(object["warnings"] as? [String])
        XCTAssertTrue(warnings.contains { $0.contains("300") })
        let candidates = try XCTUnwrap(object["data_root_candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.filter { $0["selected"] as? Bool == true }.count, 1)
    }

    func testListFeedsTruncatesAt64KiB() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)

        let feedCount = 500
        var values: [String] = []
        var outlines: [String] = []
        for index in 0..<feedCount {
            let url = "https://feed\(index).example/rss"
            let title = "Feed \(index) " + String(repeating: "long-name-", count: 6)
            values.append("('\(url)', '\(url)', '\(title)', 'https://feed\(index).example/', NULL)")
            outlines.append(
                "<outline text=\"\(title)\" title=\"\(title)\" type=\"rss\" xmlUrl=\"\(url)\"/>")
        }
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            "INSERT INTO feedSettings (feedURL, feedID, editedName, homePageURL, folderRelationship) VALUES "
                + values.joined(separator: ","))
        try root.writeOPML(
            "<?xml version=\"1.0\"?><opml version=\"1.1\"><head/><body><outline text=\"Big\" title=\"Big\">"
                + outlines.joined(separator: "\n") + "</outline></body></opml>")

        let context = try root.prepare()
        let json = try ListFeedsTool.run(context: context, now: fixedNow)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.listFeedsBytes)

        let object = try decode(json)
        XCTAssertEqual(object["truncated"] as? Bool, true)
        let omitted = try XCTUnwrap(object["omitted"] as? Int)
        XCTAssertGreaterThan(omitted, 0)
        let feeds = try XCTUnwrap(object["feeds"] as? [[String: Any]])
        XCTAssertEqual(feeds.count + omitted, feedCount)

        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        XCTAssertEqual(totals["feeds"] as? Int, feedCount)
        XCTAssertEqual(totals["folders"] as? Int, 1)

        let folders = try XCTUnwrap(object["folders"] as? [[String: Any]])
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0]["feed_count"] as? Int, feedCount)
        XCTAssertEqual(folders[0]["unread_count"] as? Int, 0)
    }

    func testOnlyUnsupportedAccountExits4() throws {
        let root = try TestRoot()
        try FileManager.default.removeItem(at: root.onMyMac)
        let accounts = root.root.appendingPathComponent("Accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accounts.appendingPathComponent("Feedly", isDirectory: true),
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 4)
            XCTAssertTrue(startupError.message.contains("暂不支持"))
            XCTAssertTrue(startupError.message.contains("Feedly"))
        }
    }

    func testUnsupportedAccountAlongsideOnMyMacIsReportedAsWarning() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        let accounts = root.root.appendingPathComponent("Accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accounts.appendingPathComponent("Feedly", isDirectory: true),
            withIntermediateDirectories: true)

        let contextWithOther = try root.prepare()
        XCTAssertEqual(contextWithOther.unsupportedAccounts, ["Feedly"])
        XCTAssertEqual(context.unsupportedAccounts, [])

        let object = try decode(
            try ListFeedsTool.run(context: contextWithOther, now: fixedNow))
        XCTAssertEqual(object["unsupported_accounts"] as? [String], ["Feedly"])
        let warnings = try XCTUnwrap(object["warnings"] as? [String])
        XCTAssertTrue(warnings.contains("暂不支持账户：Feedly"))
    }

    func testEmptyOPMLExits6() throws {
        let root = try TestRoot()
        try root.writeStandardDatabases()
        try Data().write(to: root.opmlURL)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 6)
        }
    }

    func testInvalidOPMLExits6() throws {
        let root = try TestRoot()
        try root.writeStandardDatabases()
        try root.writeOPML("<opml><body><outline text=\"broken\"></body></opml>")

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 6)
        }
    }

    func testOPMLWithoutBodyExits6() throws {
        let root = try TestRoot()
        try root.writeStandardDatabases()
        try root.writeOPML("<?xml version=\"1.0\"?><opml version=\"1.1\"><head/></opml>")

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 6)
            XCTAssertTrue(startupError.message.contains("<body>"))
        }
    }

    func testUnreadableOPMLExits6() throws {
        let root = try TestRoot()
        try root.writeStandardDatabases()
        try root.writeStandardOPML()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: root.opmlURL.path)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: root.opmlURL.path)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 6)
        }
    }

    func testDispatcherRejectsArgumentsAndUnknownTools() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()

        let withArguments = ToolDispatcher.call(
            name: "list_feeds", arguments: ["unexpected": .string("value")], context: context)
        XCTAssertEqual(withArguments.isError, true)

        let unknown = ToolDispatcher.call(
            name: "no_such_tool", arguments: nil, context: context)
        XCTAssertEqual(unknown.isError, true)

        let success = ToolDispatcher.call(
            name: "list_feeds", arguments: nil, context: context)
        XCTAssertEqual(success.isError, false)
        XCTAssertEqual(success.content.count, 1)
    }

    // MARK: - P1 helpers

    private func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func literal(_ value: Double?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    private func literal(_ value: Int?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    private func insertSearch(_ root: TestRoot, rows: [(Int, String, String)]) throws {
        let writer = try SQLiteWriter(path: root.databaseURL.path)
        let values = rows.map { "(\($0.0), \(literal($0.1)), \(literal($0.2)))" }
            .joined(separator: ",")
        try writer.exec("INSERT INTO search (docid, title, body) VALUES \(values);")
    }

    private func insertStandardSearch(_ root: TestRoot) throws {
        try insertSearch(root, rows: [
            (1, "A one", "First alpha excerpt line.\nSecond line."),
            (2, "A two", "Body two"),
            (3, "", "Body three"),
            (4, "B one", "Body four"),
            (5, "B two", "Body five"),
            (6, "C one", "Body six"),
        ])
    }

    private func insertArticle(
        _ root: TestRoot,
        id: String,
        feedID: String = "https://a.example/feed",
        title: String = "",
        url: String? = nil,
        externalURL: String? = nil,
        datePublished: Double? = nil,
        dateModified: Double? = nil,
        searchRowID: Int? = nil,
        contentText: String = "",
        authors: String? = nil,
        status: (read: Int, starred: Int, arrived: Double)? = nil
    ) throws {
        let writer = try SQLiteWriter(path: root.databaseURL.path)
        try writer.exec(
            """
            INSERT INTO articles
                (articleID, feedID, uniqueID, title, url, externalURL, datePublished,
                 dateModified, searchRowID, contentText, authors)
            VALUES (\(literal(id)), \(literal(feedID)), \(literal(id)), \(literal(title)),
                    \(literal(url)), \(literal(externalURL)), \(literal(datePublished)),
                    \(literal(dateModified)), \(literal(searchRowID)), \(literal(contentText)),
                    \(literal(authors)));
            """)
        if let status {
            try writer.exec(
                """
                INSERT INTO statuses (articleID, read, starred, dateArrived)
                VALUES (\(literal(id)), \(status.read), \(status.starred), \(status.arrived));
                """)
        }
    }

    // MARK: - list_articles

    func testListArticlesStandardValues() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertStandardSearch(root)

        let json = try ListArticlesTool.run(arguments: nil, context: context)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.listArticlesBytes)

        let decoded = try decode(json)
        XCTAssertEqual(decoded["total_matched"] as? Int, 6)
        XCTAssertEqual(decoded["returned"] as? Int, 6)
        XCTAssertEqual(decoded["omitted"] as? Int, 0)
        XCTAssertEqual(decoded["truncated"] as? Bool, false)

        let articles = try XCTUnwrap(decoded["articles"] as? [[String: Any]])
        XCTAssertEqual(articles.count, 6)
        XCTAssertEqual(
            articles.map { $0["article_id"] as? String },
            ["b1", "a1", "c1", "b2", "a2", "a3"])

        let bOne = articles[0]
        XCTAssertEqual(bOne["title"] as? String, "B one")
        XCTAssertEqual(bOne["feed_id"] as? String, "https://b.example/feed")
        XCTAssertEqual(bOne["feed_title"] as? String, "Bee Text")
        XCTAssertEqual(bOne["folder"] as? String, "News")
        XCTAssertEqual(bOne["published_at"] as? String, "2023-11-14T22:18:20Z")
        XCTAssertEqual(bOne["url"] as? String, "https://b.example/1")
        XCTAssertEqual(bOne["read"] as? Bool, true)
        XCTAssertEqual(bOne["starred"] as? Bool, true)
        XCTAssertTrue(bOne["author"] is NSNull)
        XCTAssertEqual(bOne["excerpt"] as? String, "Body four")
        XCTAssertEqual(bOne["content_chars"] as? Int, 9)

        let aOne = articles[1]
        XCTAssertEqual(aOne["title"] as? String, "A one")
        XCTAssertEqual(aOne["feed_title"] as? String, "Alpha Edited")
        XCTAssertEqual(aOne["folder"] as? String, "News")
        XCTAssertEqual(aOne["author"] as? String, "Author A")
        XCTAssertEqual(aOne["read"] as? Bool, false)
        XCTAssertEqual(aOne["starred"] as? Bool, true)
        XCTAssertEqual(
            aOne["excerpt"] as? String, "First alpha excerpt line. Second line.")
        XCTAssertEqual(aOne["content_chars"] as? Int, 38)

        let aThree = articles[5]
        XCTAssertTrue(aThree["title"] is NSNull)
        XCTAssertTrue(aThree["published_at"] is NSNull)
        XCTAssertTrue(aThree["url"] is NSNull)
        XCTAssertEqual(aThree["read"] as? Bool, false)
        XCTAssertEqual(aThree["excerpt"] as? String, "Body three")
        XCTAssertEqual(aThree["content_chars"] as? Int, 10)
        XCTAssertEqual(aThree["feed_title"] as? String, "Alpha Edited")

        let cOne = articles[2]
        XCTAssertEqual(cOne["feed_title"] as? String, "Cee Title")
        XCTAssertEqual(cOne["folder"] as? String, "Tech")
        XCTAssertEqual(cOne["read"] as? Bool, false)
    }

    func testListArticlesFiltersAndLimit() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertStandardSearch(root)

        let byFeed = try decode(
            try ListArticlesTool.run(
                arguments: ["feed_id": .string("https://b.example/feed")], context: context))
        XCTAssertEqual(byFeed["total_matched"] as? Int, 2)
        let feedArticles = try XCTUnwrap(byFeed["articles"] as? [[String: Any]])
        XCTAssertEqual(feedArticles.map { $0["article_id"] as? String }, ["b1", "b2"])
        XCTAssertTrue(feedArticles.allSatisfy { $0["feed_id"] as? String == "https://b.example/feed" })

        let unread = try decode(
            try ListArticlesTool.run(arguments: ["unread_only": .bool(true)], context: context))
        XCTAssertEqual(unread["total_matched"] as? Int, 3)
        let unreadArticles = try XCTUnwrap(unread["articles"] as? [[String: Any]])
        XCTAssertEqual(unreadArticles.map { $0["article_id"] as? String }, ["a1", "c1", "a3"])
        XCTAssertTrue(unreadArticles.allSatisfy { $0["read"] as? Bool == false })

        let combined = try decode(
            try ListArticlesTool.run(
                arguments: [
                    "feed_id": .string("https://a.example/feed"),
                    "unread_only": .bool(true),
                ], context: context))
        XCTAssertEqual(combined["total_matched"] as? Int, 2)
        XCTAssertEqual(
            (combined["articles"] as? [[String: Any]])?.map { $0["article_id"] as? String },
            ["a1", "a3"])

        let limited = try decode(
            try ListArticlesTool.run(arguments: ["limit": .int(2)], context: context))
        XCTAssertEqual(limited["total_matched"] as? Int, 6)
        XCTAssertEqual(limited["returned"] as? Int, 2)
        XCTAssertEqual(limited["omitted"] as? Int, 0)
        XCTAssertEqual((limited["articles"] as? [[String: Any]])?.count, 2)

        XCTAssertThrowsError(
            try ListArticlesTool.run(
                arguments: ["feed_id": .string("https://missing.example/feed")], context: context)
        ) { error in
            XCTAssertTrue((error as? ToolError)?.message.contains("未知 feed_id") == true)
        }
        for invalidLimit in [0, 101, -1] {
            XCTAssertThrowsError(
                try ListArticlesTool.run(arguments: ["limit": .int(invalidLimit)], context: context))
        }
        XCTAssertThrowsError(
            try ListArticlesTool.run(arguments: ["limit": .string("20")], context: context))
        XCTAssertThrowsError(
            try ListArticlesTool.run(arguments: ["unknown": .int(1)], context: context))
    }

    func testListArticlesTruncatesAt48KiB() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()

        let body = String(repeating: "文", count: 300)
        var articleValues: [String] = []
        var searchValues: [String] = []
        for index in 0..<100 {
            let id = "bulk\(index)"
            let title = "标题 \(index)"
            articleValues.append(
                "(\(literal(id)), \(literal("https://a.example/feed")), \(literal(id)), \(literal(title)), NULL, NULL, \(1700000000 + index), NULL, \(index + 1), '', NULL)"
            )
            searchValues.append("(\(index + 1), \(literal(title)), \(literal(body)))")
        }
        let writer = try SQLiteWriter(path: root.databaseURL.path)
        try writer.exec(
            """
            INSERT INTO articles
                (articleID, feedID, uniqueID, title, url, externalURL, datePublished,
                 dateModified, searchRowID, contentText, authors)
            VALUES \(articleValues.joined(separator: ","));
            """)
        try writer.exec(
            "INSERT INTO search (docid, title, body) VALUES \(searchValues.joined(separator: ","));")

        let context = try root.prepare()
        let json = try ListArticlesTool.run(arguments: ["limit": .int(100)], context: context)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.listArticlesBytes)

        let decoded = try decode(json)
        XCTAssertEqual(decoded["total_matched"] as? Int, 100)
        XCTAssertEqual(decoded["truncated"] as? Bool, true)
        let omitted = try XCTUnwrap(decoded["omitted"] as? Int)
        XCTAssertGreaterThan(omitted, 0)
        let articles = try XCTUnwrap(decoded["articles"] as? [[String: Any]])
        XCTAssertEqual(decoded["returned"] as? Int, articles.count)
        XCTAssertEqual(articles.count + omitted, 100)
        XCTAssertEqual(articles[0]["article_id"] as? String, "bulk99")
    }

    // MARK: - get_article

    func testGetArticleByArticleID() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertStandardSearch(root)

        let json = try GetArticleTool.run(
            arguments: ["article_id": .string("a1")], context: context)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.getArticleBytes)
        let decoded = try decode(json)

        XCTAssertEqual(decoded["article_id"] as? String, "a1")
        XCTAssertEqual(decoded["feed_id"] as? String, "https://a.example/feed")
        XCTAssertEqual(decoded["feed_title"] as? String, "Alpha Edited")
        XCTAssertEqual(decoded["folder"] as? String, "News")
        XCTAssertEqual(decoded["title"] as? String, "A one")
        XCTAssertEqual(decoded["url"] as? String, "https://a.example/1")
        XCTAssertTrue(decoded["external_url"] is NSNull)
        XCTAssertEqual(decoded["published_at"] as? String, "2023-11-14T22:16:40Z")
        XCTAssertEqual(decoded["modified_at"] as? String, "2023-11-14T22:16:40Z")
        XCTAssertEqual(decoded["arrived_at"] as? String, "2023-11-14T22:16:40Z")
        XCTAssertEqual(decoded["read"] as? Bool, false)
        XCTAssertEqual(decoded["starred"] as? Bool, true)
        XCTAssertEqual(decoded["authors"] as? [String], ["Author A"])
        XCTAssertEqual(decoded["content_source"] as? String, "search_index_text")
        XCTAssertEqual(decoded["content"] as? String, "First alpha excerpt line.\nSecond line.")
        XCTAssertEqual(decoded["content_total_chars"] as? Int, 38)
        XCTAssertEqual(decoded["content_chars"] as? Int, 38)
        XCTAssertEqual(decoded["content_bytes"] as? Int, 38)
        XCTAssertEqual(decoded["content_truncated"] as? Bool, false)
        XCTAssertEqual(decoded["duplicate_count"] as? Int, 1)

        try insertArticle(
            root, id: "empty1", title: "Empty", datePublished: 1700000300, searchRowID: nil)
        let empty = try decode(
            try GetArticleTool.run(arguments: ["article_id": .string("empty1")], context: context))
        XCTAssertEqual(empty["content_source"] as? String, "none")
        XCTAssertEqual(empty["content"] as? String, "")
        XCTAssertEqual(empty["content_chars"] as? Int, 0)
        XCTAssertEqual(empty["content_total_chars"] as? Int, 0)
        XCTAssertEqual(empty["content_bytes"] as? Int, 0)
        XCTAssertEqual(empty["content_truncated"] as? Bool, false)

        let noAuthors = try decode(
            try GetArticleTool.run(arguments: ["article_id": .string("a2")], context: context))
        XCTAssertEqual(noAuthors["authors"] as? [String], [])
        XCTAssertEqual(noAuthors["external_url"] as? String, "https://external.example/a2")
        XCTAssertEqual(noAuthors["duplicate_count"] as? Int, 1)
    }

    func testGetArticleByURLDuplicateAndExternalFallback() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertSearch(root, rows: [(7, "Dup old", "old body"), (8, "Dup new", "new body")])
        try insertArticle(
            root, id: "dup1", title: "Dup old", url: "https://duplicate.example/a",
            datePublished: 1700000400, searchRowID: 7, contentText: "old")
        try insertArticle(
            root, id: "dup2", title: "Dup new", url: "https://duplicate.example/a",
            datePublished: 1700000500, searchRowID: 8, contentText: "new")

        let byURL = try decode(
            try GetArticleTool.run(
                arguments: ["url": .string("https://duplicate.example/a")], context: context))
        XCTAssertEqual(byURL["article_id"] as? String, "dup2")
        XCTAssertEqual(byURL["duplicate_count"] as? Int, 2)

        let byExternal = try decode(
            try GetArticleTool.run(
                arguments: ["url": .string("https://external.example/a2")], context: context))
        XCTAssertEqual(byExternal["article_id"] as? String, "a2")
        XCTAssertEqual(byExternal["duplicate_count"] as? Int, 1)

        XCTAssertThrowsError(
            try GetArticleTool.run(
                arguments: ["url": .string("https://missing.example/none")], context: context)
        ) { error in
            XCTAssertTrue(
                (error as? ToolError)?.message.contains("https://missing.example/none") == true)
        }
        XCTAssertThrowsError(try GetArticleTool.run(arguments: nil, context: context))
        XCTAssertThrowsError(
            try GetArticleTool.run(
                arguments: ["article_id": .string("a1"), "url": .string("https://a.example/1")],
                context: context))
        XCTAssertThrowsError(
            try GetArticleTool.run(arguments: ["article_id": .string("missing")], context: context))
    }

    func testGetArticleMaxCharsTruncation() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        let content = String(repeating: "abcdefghij", count: 100)
        try insertSearch(root, rows: [(7, "Long", content)])
        try insertArticle(
            root, id: "long1", title: "Long", datePublished: 1700000400, searchRowID: 7)

        let decoded = try decode(
            try GetArticleTool.run(
                arguments: ["article_id": .string("long1"), "max_chars": .int(500)],
                context: context))
        let returned = try XCTUnwrap(decoded["content"] as? String)
        XCTAssertEqual(returned.count, 500)
        XCTAssertEqual(decoded["content_chars"] as? Int, 500)
        XCTAssertEqual(decoded["content_total_chars"] as? Int, 1000)
        XCTAssertEqual(decoded["content_bytes"] as? Int, returned.utf8.count)
        XCTAssertEqual(decoded["content_truncated"] as? Bool, true)

        for invalid in [499, 32001] {
            XCTAssertThrowsError(
                try GetArticleTool.run(
                    arguments: ["article_id": .string("long1"), "max_chars": .int(invalid)],
                    context: context))
        }
    }

    func testGetArticleContentTextFallback() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        let contentText = "Fallback 正文 only in contentText"
        try insertArticle(
            root, id: "ct1", title: "ContentText", datePublished: 1700000400,
            searchRowID: nil, contentText: contentText)

        let decoded = try decode(
            try GetArticleTool.run(arguments: ["article_id": .string("ct1")], context: context))
        XCTAssertEqual(decoded["content_source"] as? String, "contentText")
        XCTAssertEqual(decoded["content"] as? String, contentText)
        XCTAssertEqual(decoded["content_total_chars"] as? Int, contentText.count)
        XCTAssertEqual(decoded["content_truncated"] as? Bool, false)

        let listed = try decode(
            try ListArticlesTool.run(
                arguments: ["feed_id": .string("https://a.example/feed")], context: context))
        let articles = try XCTUnwrap(listed["articles"] as? [[String: Any]])
        let item = try XCTUnwrap(articles.first { $0["article_id"] as? String == "ct1" })
        XCTAssertEqual(item["excerpt"] as? String, "")
        XCTAssertEqual(item["content_chars"] as? Int, contentText.count)
    }

    func testStatusesMissingCountsAsUnread() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertSearch(root, rows: [(7, "No status", "No status body")])
        try insertArticle(
            root, id: "ns1", title: "No status", datePublished: 1700000400, searchRowID: 7,
            status: nil)

        let unread = try decode(
            try ListArticlesTool.run(
                arguments: [
                    "feed_id": .string("https://a.example/feed"),
                    "unread_only": .bool(true),
                ], context: context))
        let articles = try XCTUnwrap(unread["articles"] as? [[String: Any]])
        let item = try XCTUnwrap(articles.first { $0["article_id"] as? String == "ns1" })
        XCTAssertEqual(item["read"] as? Bool, false)
        XCTAssertEqual(item["starred"] as? Bool, false)

        let decoded = try decode(
            try GetArticleTool.run(arguments: ["article_id": .string("ns1")], context: context))
        XCTAssertEqual(decoded["read"] as? Bool, false)
        XCTAssertEqual(decoded["starred"] as? Bool, false)
        XCTAssertTrue(decoded["arrived_at"] is NSNull)
    }

    func testGetArticleTruncatesTo96KiB() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        let emoji = String(repeating: "😀", count: 32000)
        try insertSearch(root, rows: [(7, "Emoji", emoji)])
        try insertArticle(
            root, id: "big1", title: "Emoji", datePublished: 1700000400, searchRowID: 7)

        let json = try GetArticleTool.run(
            arguments: ["article_id": .string("big1"), "max_chars": .int(32000)],
            context: context)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.getArticleBytes)

        let decoded = try decode(json)
        let content = try XCTUnwrap(decoded["content"] as? String)
        let chars = try XCTUnwrap(decoded["content_chars"] as? Int)
        let total = try XCTUnwrap(decoded["content_total_chars"] as? Int)
        XCTAssertEqual(total, 32000)
        XCTAssertLessThan(chars, total)
        XCTAssertEqual(chars, content.count)
        XCTAssertEqual(decoded["content_bytes"] as? Int, content.utf8.count)
        XCTAssertEqual(decoded["content_truncated"] as? Bool, true)
    }

    func testP1ToolsOpenExactlyOneConnection() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertStandardSearch(root)

        ReadOnlyDatabase.connectionCounter.reset()
        _ = try ListArticlesTool.run(arguments: nil, context: context)
        XCTAssertEqual(ReadOnlyDatabase.connectionCounter.count, 1)

        ReadOnlyDatabase.connectionCounter.reset()
        _ = try GetArticleTool.run(arguments: ["article_id": .string("a1")], context: context)
        XCTAssertEqual(ReadOnlyDatabase.connectionCounter.count, 1)
    }

    // MARK: - P1 follow-up: orphan feed ids and author shapes

    func testOrphanFeedIDIsListedAndFilterable() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertStandardSearch(root)
        try insertSearch(root, rows: [(7, "Orphan", "Orphan body")])
        try insertArticle(
            root, id: "orphan1", feedID: "https://orphan.example/feed", title: "Orphan",
            datePublished: 1_700_000_600, searchRowID: 7)

        let unfiltered = try decode(
            try ListArticlesTool.run(arguments: nil, context: context))
        let unfilteredArticles = try XCTUnwrap(unfiltered["articles"] as? [[String: Any]])
        let orphan = try XCTUnwrap(
            unfilteredArticles.first { $0["article_id"] as? String == "orphan1" })
        XCTAssertEqual(orphan["feed_id"] as? String, "https://orphan.example/feed")
        XCTAssertEqual(orphan["feed_title"] as? String, "https://orphan.example/feed")
        XCTAssertTrue(orphan["folder"] is NSNull)

        let filtered = try decode(
            try ListArticlesTool.run(
                arguments: ["feed_id": .string("https://orphan.example/feed")], context: context))
        XCTAssertEqual(filtered["total_matched"] as? Int, 1)
        let filteredArticles = try XCTUnwrap(filtered["articles"] as? [[String: Any]])
        XCTAssertEqual(filteredArticles.map { $0["article_id"] as? String }, ["orphan1"])
        XCTAssertEqual(
            filteredArticles[0]["feed_title"] as? String, "https://orphan.example/feed")
        XCTAssertTrue(filteredArticles[0]["folder"] is NSNull)
    }

    func testFeedURLIsNotAcceptedAsFeedID() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES ('https://settings-only.example/feed', 'settings-feed-id', 'Settings Only');
            """
        )

        // `feedID` is known even without articles, so filtering succeeds with 0 rows.
        let byID = try decode(
            try ListArticlesTool.run(
                arguments: ["feed_id": .string("settings-feed-id")], context: context))
        XCTAssertEqual(byID["total_matched"] as? Int, 0)

        // The `feedURL` column is not part of the known set and must not be
        // silently accepted as a feed id.
        XCTAssertThrowsError(
            try ListArticlesTool.run(
                arguments: ["feed_id": .string("https://settings-only.example/feed")],
                context: context)
        ) { error in
            XCTAssertTrue((error as? ToolError)?.message.contains("未知 feed_id") == true)
        }
    }

    func testAuthorShapesInGetArticleAndListArticles() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertArticle(
            root, id: "au-empty", title: "Empty", datePublished: 1_700_000_400, authors: "[]")
        try insertArticle(
            root, id: "au-invalid", title: "Invalid", datePublished: 1_700_000_300,
            authors: "not json")
        try insertArticle(
            root, id: "au-mixed", title: "Mixed", datePublished: 1_700_000_200,
            authors: "[{\"name\":\"A\"},{\"nope\":1}]")
        try insertArticle(
            root, id: "au-null", title: "Null", datePublished: 1_700_000_100, authors: nil)

        let expected: [String: Any] = [
            "au-empty": [String](),
            "au-invalid": NSNull(),
            "au-mixed": ["A"],
            "au-null": NSNull(),
        ]
        for (articleID, authors) in expected {
            let object = try decode(
                try GetArticleTool.run(
                    arguments: ["article_id": .string(articleID)], context: context))
            XCTAssertTrue(object.keys.contains("authors"), "\(articleID) 缺少 authors 键")
            if let array = authors as? [String] {
                XCTAssertEqual(object["authors"] as? [String], array, articleID)
            } else {
                XCTAssertTrue(object["authors"] is NSNull, "\(articleID) 应为 null")
            }
        }

        let listed = try decode(
            try ListArticlesTool.run(
                arguments: [
                    "feed_id": .string("https://a.example/feed"), "limit": .int(100),
                ], context: context))
        let articles = try XCTUnwrap(listed["articles"] as? [[String: Any]])
        let authorByID = Dictionary(
            uniqueKeysWithValues: articles.map {
                ($0["article_id"] as? String ?? "", $0["author"] ?? NSNull())
            })
        XCTAssertTrue(authorByID["au-empty"] is NSNull)
        XCTAssertTrue(authorByID["au-invalid"] is NSNull)
        XCTAssertEqual(authorByID["au-mixed"] as? String, "A")
        XCTAssertTrue(authorByID["au-null"] is NSNull)
    }

    // MARK: - search_articles

    func testSearchArticlesASCIITerms() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertStandardSearch(root)

        let body = try decode(
            try SearchArticlesTool.run(arguments: ["query": .string("body")], context: context))
        XCTAssertEqual(body["query"] as? String, "body")
        XCTAssertEqual(body["mode_used"] as? String, "terms")
        XCTAssertEqual(body["total_matched"] as? Int, 5)
        let articles = try XCTUnwrap(body["articles"] as? [[String: Any]])
        XCTAssertEqual(
            articles.map { $0["article_id"] as? String },
            ["b1", "c1", "b2", "a2", "a3"])
        XCTAssertEqual(articles[0]["feed_title"] as? String, "Bee Text")
        XCTAssertEqual(articles[4]["title"] as? String, nil)
        XCTAssertTrue(articles[4]["title"] is NSNull)

        // `total_matched` does not depend on `limit`.
        let limited = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("body"), "limit": .int(1)], context: context))
        XCTAssertEqual(limited["total_matched"] as? Int, 5)
        XCTAssertEqual(limited["returned"] as? Int, 1)
        XCTAssertEqual(limited["omitted"] as? Int, 0)

        let alpha = try decode(
            try SearchArticlesTool.run(arguments: ["query": .string("alpha")], context: context))
        XCTAssertEqual(alpha["total_matched"] as? Int, 1)
    }

    func testSearchArticlesOperatorsAreLiteralTerms() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertSearch(root, rows: [(7, "Boolean", "alpha beta")])
        try insertArticle(
            root, id: "bool1", title: "Boolean", datePublished: 1_700_000_400, searchRowID: 7)

        let plain = try decode(
            try SearchArticlesTool.run(arguments: ["query": .string("alpha")], context: context))
        XCTAssertEqual(plain["total_matched"] as? Int, 1)

        let operatorLiteral = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("alpha AND")], context: context))
        XCTAssertEqual(operatorLiteral["mode_used"] as? String, "terms")
        XCTAssertEqual(operatorLiteral["total_matched"] as? Int, 0)
    }

    func testSearchArticlesCJKUsesSubstring() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertSearch(root, rows: [
            (7, "中文标题", "这是正文"),
            (8, "另一个标题", "这是另一段正文"),
        ])
        try insertArticle(
            root, id: "cjk1", title: "中文标题", datePublished: 1_700_000_400, searchRowID: 7)
        try insertArticle(
            root, id: "cjk2", title: "另一个标题", datePublished: 1_700_000_300, searchRowID: 8)

        let byBody = try decode(
            try SearchArticlesTool.run(arguments: ["query": .string("正文")], context: context))
        XCTAssertEqual(byBody["mode_used"] as? String, "substring")
        XCTAssertEqual(byBody["total_matched"] as? Int, 2)
        XCTAssertEqual(
            (byBody["articles"] as? [[String: Any]])?.map { $0["article_id"] as? String },
            ["cjk1", "cjk2"])

        let byTitle = try decode(
            try SearchArticlesTool.run(arguments: ["query": .string("中文")], context: context))
        XCTAssertEqual(byTitle["total_matched"] as? Int, 1)

        // The substring only matches as a whole FTS token, which CJK text is not.
        let directDatabase = try ReadOnlyDatabase(path: root.databaseURL.path)
        let ftsDirect =
            try directDatabase.withReadTransaction {
                try directDatabase.scalarInt(
                    "SELECT count(*) FROM search WHERE search MATCH ?",
                    binds: [.text("\"正文\"")])
            } ?? 0
        XCTAssertEqual(ftsDirect, 0)
    }

    func testSearchArticlesHybridIntersects() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertSearch(root, rows: [
            (7, "Alpha 中文", "hybrid body 中文 keyword"),
            (8, "Alpha only", "body without CJK"),
            (9, "中文 only", "中文 body"),
        ])
        try insertArticle(
            root, id: "hy1", title: "Alpha 中文", datePublished: 1_700_000_400, searchRowID: 7)
        try insertArticle(
            root, id: "hy2", title: "Alpha only", datePublished: 1_700_000_300, searchRowID: 8)
        try insertArticle(
            root, id: "hy3", title: "中文 only", datePublished: 1_700_000_200, searchRowID: 9)

        let hybrid = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("Alpha 中文")], context: context))
        XCTAssertEqual(hybrid["mode_used"] as? String, "hybrid")
        XCTAssertEqual(hybrid["total_matched"] as? Int, 1)
        let articles = try XCTUnwrap(hybrid["articles"] as? [[String: Any]])
        XCTAssertEqual(articles.map { $0["article_id"] as? String }, ["hy1"])

        // Both classes inside one token also split and intersect.
        let joined = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("Alpha中文")], context: context))
        XCTAssertEqual(joined["mode_used"] as? String, "hybrid")
        XCTAssertEqual(joined["total_matched"] as? Int, 1)
    }

    func testSearchArticlesSnippetFollowsFirstHit() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        let bodyText = String(repeating: "x", count: 500) + "needle" + String(repeating: "y", count: 500)
        try insertSearch(root, rows: [
            (7, "Needle in title", bodyText),
            (8, String(repeating: "z", count: 200) + "中文" + "tail", "needle body"),
        ])
        try insertArticle(
            root, id: "snip1", title: "Needle in title", datePublished: 1_700_000_400,
            searchRowID: 7)
        try insertArticle(
            root, id: "snip2", title: "Plain title", datePublished: 1_700_000_300, searchRowID: 8)

        let titleHit = try decode(
            try SearchArticlesTool.run(arguments: ["query": .string("needle")], context: context))
        let titleSnippet = try XCTUnwrap(
            (titleHit["articles"] as? [[String: Any]])?.first?["snippet"] as? String)
        XCTAssertLessThanOrEqual(titleSnippet.count, ContentLimits.snippetMaximumCharacters)
        XCTAssertTrue(titleSnippet.hasPrefix("Needle in title"))

        let bodyHit = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("needle")], context: context))
        // Both snippets satisfy the 400-character bound.
        for article in (bodyHit["articles"] as? [[String: Any]]) ?? [] {
            XCTAssertLessThanOrEqual(
                (article["snippet"] as? String)?.count ?? 0,
                ContentLimits.snippetMaximumCharacters)
        }

        // Hybrid prefers the CJK term's position, which is in the title.
        let hybrid = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("needle 中文")], context: context))
        let snippets = (hybrid["articles"] as? [[String: Any]])?.compactMap {
            $0["snippet"] as? String
        } ?? []
        let cjkSnippet = try XCTUnwrap(snippets.first { $0.contains("中文") })
        XCTAssertFalse(cjkSnippet.contains("needle"))
    }

    func testSearchArticlesTruncatesAt32KiB() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()

        let title = String(repeating: "长标题", count: 50)
        let body = "bulk " + String(repeating: "内容", count: 200)
        var searchValues: [String] = []
        var articleValues: [String] = []
        for index in 0..<50 {
            let id = "big\(index)"
            searchValues.append("(\(index + 1), \(literal(title)), \(literal(body)))")
            articleValues.append(
                "(\(literal(id)), \(literal("https://a.example/feed")), \(literal(id)), \(literal(title)), NULL, NULL, \(1_700_000_000 + index), NULL, \(index + 1), '', NULL)"
            )
        }
        let writer = try SQLiteWriter(path: root.databaseURL.path)
        try writer.exec(
            "INSERT INTO search (docid, title, body) VALUES \(searchValues.joined(separator: ","));")
        try writer.exec(
            """
            INSERT INTO articles
                (articleID, feedID, uniqueID, title, url, externalURL, datePublished,
                 dateModified, searchRowID, contentText, authors)
            VALUES \(articleValues.joined(separator: ","));
            """)

        let context = try root.prepare()
        let json = try SearchArticlesTool.run(
            arguments: ["query": .string("bulk"), "limit": .int(50)], context: context)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.searchArticlesBytes)

        let decoded = try decode(json)
        XCTAssertEqual(decoded["total_matched"] as? Int, 50)
        XCTAssertEqual(decoded["truncated"] as? Bool, true)
        let omitted = try XCTUnwrap(decoded["omitted"] as? Int)
        XCTAssertGreaterThan(omitted, 0)
        let articles = try XCTUnwrap(decoded["articles"] as? [[String: Any]])
        XCTAssertEqual(decoded["returned"] as? Int, articles.count)
        XCTAssertEqual(articles.count + omitted, 50)
        XCTAssertEqual(articles[0]["article_id"] as? String, "big49")
    }

    func testSearchArticlesRejectsEmptyAndInvalidArguments() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()

        for query in ["!!!", ".,;", "?!"] {
            XCTAssertThrowsError(
                try SearchArticlesTool.run(
                    arguments: ["query": .string(query)], context: context)
            ) { error in
                XCTAssertEqual((error as? ToolError)?.message.contains("词项"), true)
            }
        }
        XCTAssertThrowsError(
            try SearchArticlesTool.run(arguments: ["query": .string("   ")], context: context)
        ) { error in
            XCTAssertEqual((error as? ToolError)?.message.contains("不能为空"), true)
        }
        XCTAssertThrowsError(
            try SearchArticlesTool.run(arguments: nil, context: context))
        XCTAssertThrowsError(
            try SearchArticlesTool.run(
                arguments: ["query": .string(String(repeating: "a", count: 201))],
                context: context))
        for badLimit in [0, 51] {
            XCTAssertThrowsError(
                try SearchArticlesTool.run(
                    arguments: ["query": .string("a"), "limit": .int(badLimit)], context: context))
        }
    }

    func testSearchLikeBudgetInterrupts() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeStandardOPML()
        let writer = try SQLiteWriter(path: root.databaseURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES ('https://a.example/feed', 'https://a.example/feed', 'Alpha');
            """)

        let bodyText = String(repeating: "数据库检索预算", count: 400)
        let articleCount = 1000
        let batchSize = 20
        var index = 0
        while index < articleCount {
            let upper = min(index + batchSize, articleCount)
            var searchValues: [String] = []
            var articleValues: [String] = []
            for row in index..<upper {
                searchValues.append(
                    "(\(row + 1), \(literal("标题 \(row)")), \(literal(bodyText)))")
                articleValues.append(
                    "(\(literal("slow\(row)")), \(literal("https://a.example/feed")), \(literal("slow\(row)")), \(literal("标题 \(row)")), NULL, NULL, \(1_700_000_000 + row), NULL, \(row + 1), '', NULL)"
                )
            }
            try writer.exec(
                "INSERT INTO search (docid, title, body) VALUES \(searchValues.joined(separator: ","));")
            try writer.exec(
                """
                INSERT INTO articles
                    (articleID, feedID, uniqueID, title, url, externalURL, datePublished,
                     dateModified, searchRowID, contentText, authors)
                VALUES \(articleValues.joined(separator: ","));
                """)
            index = upper
        }

        let context = try root.prepare()

        XCTAssertThrowsError(
            try SearchArticlesTool.run(
                arguments: ["query": .string("检索")], context: context,
                likeBudgetMilliseconds: 1)
        ) { error in
            XCTAssertTrue(
                (error as? ToolError)?.message.contains("检索超时") == true,
                "实际错误：\(error)")
        }

        let completed = try decode(
            try SearchArticlesTool.run(
                arguments: ["query": .string("检索")], context: context,
                likeBudgetMilliseconds: 60_000))
        XCTAssertEqual(completed["total_matched"] as? Int, articleCount)
    }

    // MARK: - unread_digest

    func testUnreadDigestWindowBoundariesAndTotals() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeOPML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="1.1"><head/><body>
                <outline text="News" title="News">
                    <outline text="Feed One" title="Feed One" type="rss" xmlUrl="https://f1.example/feed"/>
                    <outline text="Feed Two" title="Feed Two" type="rss" xmlUrl="https://f2.example/feed"/>
                </outline>
            </body></opml>
            """
        )
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName) VALUES
                ('https://f1.example/feed', 'https://f1.example/feed', 'Feed One'),
                ('https://f2.example/feed', 'https://f2.example/feed', 'Feed Two');
            """
        )

        let now = fixedNow.timeIntervalSince1970
        let sinceOneDay = now - 86400
        func article(_ id: String, feed: String, at date: Double?, read: Int) throws {
            try insertArticle(
                root, id: id, feedID: feed, title: id, datePublished: date,
                status: (read: read, starred: 0, arrived: date ?? 0))
        }
        try article("w1", feed: "https://f1.example/feed", at: now - 3600, read: 0)
        try article("w2", feed: "https://f1.example/feed", at: now - 1800, read: 1)
        try article("w3", feed: "https://f1.example/feed", at: now - 100, read: 0)
        try article("w4", feed: "https://f1.example/feed", at: now + 100, read: 0)
        try article("w5", feed: "https://f1.example/feed", at: nil, read: 0)
        try article("out1", feed: "https://f1.example/feed", at: now - 100_000, read: 0)
        try article("w6", feed: "https://f2.example/feed", at: now - 200, read: 0)
        try article("e1", feed: "https://f2.example/feed", at: sinceOneDay, read: 0)
        try article("e2", feed: "https://f2.example/feed", at: now, read: 0)

        let context = try root.prepare()
        let oneDay = try decode(
            try UnreadDigestTool.run(
                arguments: ["days": .int(1)], context: context, now: fixedNow))
        let window = try XCTUnwrap(oneDay["window"] as? [String: Any])
        XCTAssertEqual(window["since"] as? String, "2027-01-14T08:00:00Z")
        XCTAssertEqual(window["until"] as? String, "2027-01-15T08:00:00Z")

        let totals = try XCTUnwrap(oneDay["totals"] as? [String: Any])
        XCTAssertEqual(totals["unread_total"] as? Int, 8)
        XCTAssertEqual(totals["unread_in_window"] as? Int, 5)
        XCTAssertEqual(totals["articles_in_window"] as? Int, 6)
        XCTAssertEqual(totals["unread_feeds"] as? Int, 2)

        let feeds = try XCTUnwrap(oneDay["feeds"] as? [[String: Any]])
        XCTAssertEqual(feeds.map { $0["feed_id"] as? String }, [
            "https://f2.example/feed", "https://f1.example/feed",
        ])
        let f1 = feeds[1]
        XCTAssertEqual(f1["title"] as? String, "Feed One")
        XCTAssertEqual(f1["folder"] as? String, "News")
        XCTAssertEqual(f1["unread_total"] as? Int, 5)
        XCTAssertEqual(f1["unread_in_window"] as? Int, 2)
        XCTAssertEqual(f1["latest_published_at"] as? String, "2027-01-15T07:58:20Z")
        XCTAssertEqual(
            (f1["articles"] as? [[String: Any]])?.map { $0["article_id"] as? String },
            ["w3", "w1"])

        let f2 = feeds[0]
        XCTAssertEqual(f2["unread_in_window"] as? Int, 3)
        XCTAssertEqual(f2["latest_published_at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(
            (f2["articles"] as? [[String: Any]])?.map { $0["article_id"] as? String },
            ["e2", "w6", "e1"])

        // D1 and D19.
        let sumOneDay = feeds.reduce(0) { $0 + ($1["unread_in_window"] as? Int ?? 0) }
        XCTAssertEqual(
            sumOneDay + (oneDay["omitted_unread_in_window"] as? Int ?? 0),
            totals["unread_in_window"] as? Int)
        XCTAssertEqual(
            totals["unread_feeds"] as? Int,
            feeds.count + (oneDay["omitted_feeds"] as? Int ?? 0))
        XCTAssertEqual(oneDay["truncated"] as? Bool, false)

        let sevenDays = try decode(
            try UnreadDigestTool.run(
                arguments: ["days": .int(7)], context: context, now: fixedNow))
        let sevenTotals = try XCTUnwrap(sevenDays["totals"] as? [String: Any])
        XCTAssertEqual(sevenTotals["unread_total"] as? Int, 8)
        XCTAssertEqual(sevenTotals["unread_in_window"] as? Int, 6)
        XCTAssertEqual(sevenTotals["articles_in_window"] as? Int, 7)
        let sevenFeeds = try XCTUnwrap(sevenDays["feeds"] as? [[String: Any]])
        let sevenSum = sevenFeeds.reduce(0) { $0 + ($1["unread_in_window"] as? Int ?? 0) }
        XCTAssertEqual(
            sevenSum + (sevenDays["omitted_unread_in_window"] as? Int ?? 0),
            sevenTotals["unread_in_window"] as? Int)
    }

    func testUnreadDigestExcludesEmptyFeedID() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeOPML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="1.1"><head/><body>
                <outline text="News" title="News">
                    <outline text="Feed One" title="Feed One" type="rss" xmlUrl="https://f1.example/feed"/>
                </outline>
            </body></opml>
            """
        )
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES ('https://f1.example/feed', 'https://f1.example/feed', 'Feed One');
            """
        )

        let now = fixedNow.timeIntervalSince1970
        try insertArticle(
            root, id: "good1", feedID: "https://f1.example/feed", title: "Good",
            datePublished: now - 100, status: (read: 0, starred: 0, arrived: now - 100))
        // Empty feedID is not a recognizable feed; it must not be counted in
        // any digest total (D1/D2 must still agree).
        try insertArticle(
            root, id: "empty1", feedID: "", title: "Empty feed",
            datePublished: now - 200, status: (read: 0, starred: 0, arrived: now - 200))
        try insertArticle(
            root, id: "empty2", feedID: "", title: "Empty feed read",
            datePublished: now - 300, status: (read: 1, starred: 0, arrived: now - 300))

        let context = try root.prepare()
        let decoded = try decode(
            try UnreadDigestTool.run(
                arguments: ["days": .int(1)], context: context, now: fixedNow))
        let totals = try XCTUnwrap(decoded["totals"] as? [String: Any])
        XCTAssertEqual(totals["unread_total"] as? Int, 1)
        XCTAssertEqual(totals["unread_in_window"] as? Int, 1)
        XCTAssertEqual(totals["articles_in_window"] as? Int, 1)
        XCTAssertEqual(totals["unread_feeds"] as? Int, 1)

        let feeds = try XCTUnwrap(decoded["feeds"] as? [[String: Any]])
        XCTAssertEqual(feeds.map { $0["feed_id"] as? String }, ["https://f1.example/feed"])
        let sum = feeds.reduce(0) { $0 + ($1["unread_in_window"] as? Int ?? 0) }
        XCTAssertEqual(
            sum + (decoded["omitted_unread_in_window"] as? Int ?? 0),
            totals["unread_in_window"] as? Int)
        XCTAssertEqual(
            totals["unread_feeds"] as? Int,
            feeds.count + (decoded["omitted_feeds"] as? Int ?? 0))
    }

    func testUnreadDigestTruncatesWholeFeeds() throws {
        let root = try TestRoot()
        try root.writeDatabases(schema: try Fixture.sql("schema"), includeSeed: false)
        try root.writeOPML(
            "<?xml version=\"1.0\"?><opml version=\"1.1\"><head/><body></body></opml>")

        let feedCount = 300
        var settingsValues: [String] = []
        var articleValues: [String] = []
        for index in 0..<feedCount {
            let feedID = "https://feed\(index).example/rss"
            let title = "Feed \(index) " + String(repeating: "long-name-", count: 8)
            settingsValues.append(
                "(\(literal(feedID)), \(literal(feedID)), \(literal(title)))")
            articleValues.append(
                "(\(literal("digest\(index)")), \(literal(feedID)), \(literal("digest\(index)")), \(literal("Article \(index)")), NULL, NULL, \(1_799_999_000), NULL, NULL, '', NULL)"
            )
        }
        let writer = try SQLiteWriter(path: root.feedSettingsURL.path)
        try writer.exec(
            """
            INSERT INTO feedSettings (feedURL, feedID, editedName)
            VALUES \(settingsValues.joined(separator: ","));
            """)
        let articleWriter = try SQLiteWriter(path: root.databaseURL.path)
        try articleWriter.exec(
            """
            INSERT INTO articles
                (articleID, feedID, uniqueID, title, url, externalURL, datePublished,
                 dateModified, searchRowID, contentText, authors)
            VALUES \(articleValues.joined(separator: ","));
            """)

        let context = try root.prepare()
        let json = try UnreadDigestTool.run(
            arguments: ["days": .int(1)], context: context, now: fixedNow)
        XCTAssertLessThanOrEqual(json.utf8.count, ContentLimits.unreadDigestBytes)

        let decoded = try decode(json)
        let totals = try XCTUnwrap(decoded["totals"] as? [String: Any])
        let feeds = try XCTUnwrap(decoded["feeds"] as? [[String: Any]])
        let omittedFeeds = try XCTUnwrap(decoded["omitted_feeds"] as? Int)
        let omittedUnread = try XCTUnwrap(decoded["omitted_unread_in_window"] as? Int)

        XCTAssertEqual(totals["unread_in_window"] as? Int, feedCount)
        XCTAssertGreaterThan(omittedFeeds, 0)
        XCTAssertEqual(decoded["truncated"] as? Bool, true)
        let sum = feeds.reduce(0) { $0 + ($1["unread_in_window"] as? Int ?? 0) }
        XCTAssertEqual(sum + omittedUnread, totals["unread_in_window"] as? Int)
        XCTAssertEqual(
            totals["unread_feeds"] as? Int, feeds.count + omittedFeeds)
        for feed in feeds {
            let articles = feed["articles"] as? [[String: Any]] ?? []
            XCTAssertLessThanOrEqual(articles.count, UnreadDigestTool.maxArticlesPerFeed)
        }
    }

    func testP2ToolsOpenExactlyOneConnection() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        try insertStandardSearch(root)
        try insertArticle(
            root, id: "conn1", title: "Conn", datePublished: 1_700_000_400, searchRowID: 1)

        ReadOnlyDatabase.connectionCounter.reset()
        _ = try SearchArticlesTool.run(arguments: ["query": .string("body")], context: context)
        XCTAssertEqual(ReadOnlyDatabase.connectionCounter.count, 1)

        ReadOnlyDatabase.connectionCounter.reset()
        _ = try UnreadDigestTool.run(arguments: nil, context: context, now: fixedNow)
        XCTAssertEqual(ReadOnlyDatabase.connectionCounter.count, 1)
    }
}
