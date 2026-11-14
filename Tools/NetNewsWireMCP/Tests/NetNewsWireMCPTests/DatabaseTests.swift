import Foundation
import XCTest

@testable import NetNewsWireMCPCore

final class DatabaseTests: XCTestCase {
    func testFixtureSchemaPasses() throws {
        let root = try TestRoot()
        XCTAssertNoThrow(try root.createStandardServerContext())
    }

    func testZeroByteDatabaseExits5() throws {
        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeStandardDatabases()
        try Data().write(to: root.databaseURL)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 5)
            XCTAssertTrue(startupError.message.contains("0 字节"))
            XCTAssertTrue(startupError.message.contains(root.databaseURL.path))
        }
    }

    func testNonDatabaseFileExits5() throws {
        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeStandardDatabases()
        try Data("this is not a sqlite database".utf8).write(to: root.databaseURL)

        XCTAssertThrowsError(try root.prepare()) { error in
            let startupError = error as? StartupError
            XCTAssertEqual(startupError?.code, 5)
        }
    }

    func testUnreadableDatabaseExits5() throws {
        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeStandardDatabases()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: root.databaseURL.path)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: root.databaseURL.path)

        XCTAssertThrowsError(try root.prepare()) { error in
            let startupError = error as? StartupError
            XCTAssertEqual(startupError?.code, 5)
        }
    }

    func testMissingRequiredFileExits4() throws {
        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeStandardDatabases()
        try FileManager.default.removeItem(at: root.opmlURL)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 4)
            XCTAssertTrue(startupError.message.contains("Subscriptions.opml"))
        }
    }

    func testMissingArticleColumnExits3() throws {
        let standard = try Fixture.sql("schema")
        let missingColumn = standard.replacingOccurrences(of: "    authors TEXT,\n", with: "")
        XCTAssertNotEqual(standard, missingColumn, "fixture 文本变化，测试需要更新")

        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeDatabase(at: root.databaseURL, schema: missingColumn, seed: nil)
        try root.writeDatabase(at: root.feedSettingsURL, schema: standard, seed: nil)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 3)
            XCTAssertTrue(startupError.message.contains("authors"))
        }
    }

    func testSearchNotFTS4Exits3() throws {
        let standard = try Fixture.sql("schema")
        let notFTS = standard.replacingOccurrences(
            of: "CREATE VIRTUAL TABLE search USING fts4(title, body);",
            with: "CREATE TABLE search (title TEXT, body TEXT);")
        XCTAssertNotEqual(standard, notFTS, "fixture 文本变化，测试需要更新")

        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeDatabase(at: root.databaseURL, schema: notFTS, seed: nil)
        try root.writeDatabase(at: root.feedSettingsURL, schema: standard, seed: nil)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 3)
            XCTAssertTrue(startupError.message.contains("FTS4"))
        }
    }

    func testMissingSearchTriggerExits3() throws {
        let standard = try Fixture.sql("schema")
        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeDatabase(at: root.databaseURL, schema: standard, seed: nil)
        try root.writeDatabase(at: root.feedSettingsURL, schema: standard, seed: nil)

        let writer = try SQLiteWriter(path: root.databaseURL.path)
        try writer.exec("DROP TRIGGER articles_after_delete_trigger_delete_search_text;")

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 3)
            XCTAssertTrue(startupError.message.contains("trigger"))
        }
    }

    func testMissingFeedSettingsTableExits3() throws {
        let standard = try Fixture.sql("schema")
        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeDatabase(at: root.databaseURL, schema: standard, seed: nil)
        try root.writeDatabase(
            at: root.feedSettingsURL, schema: "CREATE TABLE other (id TEXT);", seed: nil)

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 3)
            XCTAssertTrue(startupError.message.contains("feedSettings"))
        }
    }

    func testAttachedFeedSettingsSharesOneReadOnlyConnection() throws {
        let root = try TestRoot()
        try root.writeStandardDatabases()
        let database = try ReadOnlyDatabase(path: root.databaseURL.path)
        try database.attachReadOnlyDatabase(at: root.feedSettingsURL.path)

        let databaseNames = try database.withReadTransaction {
            try database.query("PRAGMA database_list").compactMap {
                $0.count > 1 ? $0[1].stringValue : nil
            }
        }
        XCTAssertEqual(databaseNames.sorted(), ["fs", "main"])

        let feedCount = try database.withReadTransaction {
            try database.scalarInt("SELECT count(*) FROM fs.feedSettings")
        }
        XCTAssertEqual(feedCount, 4)

        XCTAssertThrowsError(
            try database.execute("INSERT INTO fs.feedSettings (feedURL) VALUES ('should-fail')")
        )
    }

    func testAttachEscapesSingleQuoteInPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nnw-mcp-quote's-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try TestRoot(root: base.appendingPathComponent("NetNewsWire", isDirectory: true))
        try root.writeStandardDatabases()

        XCTAssertTrue(root.feedSettingsURL.path.contains("'"))
        let database = try ReadOnlyDatabase(path: root.databaseURL.path)
        try database.attachReadOnlyDatabase(at: root.feedSettingsURL.path)
        let count = try database.withReadTransaction {
            try database.scalarInt("SELECT count(*) FROM fs.feedSettings")
        }
        XCTAssertEqual(count, 4)
    }

    func testTriggerReferenceMustBeTheTableNotSearchRowID() throws {
        let standard = try Fixture.sql("schema")
        let root = try TestRoot()
        try root.writeStandardOPML()
        try root.writeDatabase(at: root.databaseURL, schema: standard, seed: nil)
        try root.writeDatabase(at: root.feedSettingsURL, schema: standard, seed: nil)

        let writer = try SQLiteWriter(path: root.databaseURL.path)
        try writer.exec("DROP TRIGGER articles_after_delete_trigger_delete_search_text;")
        try writer.exec(
            """
            CREATE TRIGGER fake_trigger_using_only_searchRowID
            AFTER DELETE ON articles
            BEGIN
                SELECT OLD.searchRowID;
            END;
            """
        )

        XCTAssertThrowsError(try root.prepare()) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 3)
            XCTAssertTrue(startupError.message.contains("trigger"))
        }
    }

    func testReadOnlyDatabaseRejectsWrites() throws {
        let root = try TestRoot()
        try root.writeStandardDatabases()
        let database = try ReadOnlyDatabase(path: root.databaseURL.path)
        XCTAssertThrowsError(
            try database.execute("INSERT INTO statuses (articleID) VALUES ('should-fail')")
        ) { error in
            XCTAssertTrue(error is DatabaseError)
        }
    }
}
