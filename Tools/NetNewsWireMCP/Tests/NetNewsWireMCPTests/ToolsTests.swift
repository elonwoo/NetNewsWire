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

    func testToolCatalogIsP0Only() {
        XCTAssertEqual(ToolCatalog.serverTools.count, 1)
        let tool = ToolCatalog.serverTools[0]
        XCTAssertEqual(tool.name, "list_feeds")
        XCTAssertEqual(tool.annotations.readOnlyHint, true)
        XCTAssertEqual(tool.annotations.destructiveHint, false)
        XCTAssertEqual(tool.annotations.idempotentHint, true)
        XCTAssertEqual(tool.annotations.openWorldHint, false)
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
}
