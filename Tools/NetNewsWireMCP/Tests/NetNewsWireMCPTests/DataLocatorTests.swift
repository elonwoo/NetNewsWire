import Foundation
import SQLite3
import XCTest

@testable import NetNewsWireMCPCore

struct TestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum Fixture {
    static func sql(_ name: String) throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "sql", subdirectory: "Fixtures")
        else {
            throw TestError(message: "缺少测试 fixture：\(name).sql")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let standardOPML = """
        <?xml version="1.0" encoding="UTF-8"?>
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
}

final class SQLiteWriter {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let database else {
            throw TestError(message: "无法创建测试数据库 \(path)：\(result)")
        }
        handle = database
    }

    func exec(_ sql: String) throws {
        guard let handle else { throw TestError(message: "测试数据库已关闭") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "未知错误"
            if let errorMessage { sqlite3_free(errorMessage) }
            throw TestError(message: "执行 SQL 失败：\(detail)\nSQL: \(sql.prefix(200))")
        }
        if let errorMessage { sqlite3_free(errorMessage) }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }
}

final class TestRoot {
    let base: URL
    let root: URL
    let onMyMac: URL

    init(root: URL? = nil) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nnw-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        self.root = root ?? base.appendingPathComponent("NetNewsWire", isDirectory: true)
        onMyMac = self.root
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent("OnMyMac", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: onMyMac, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var databaseURL: URL { onMyMac.appendingPathComponent(DataRootConstants.databaseFileName) }
    var feedSettingsURL: URL { onMyMac.appendingPathComponent(DataRootConstants.feedSettingsFileName) }
    var opmlURL: URL { onMyMac.appendingPathComponent(DataRootConstants.subscriptionsFileName) }

    var environment: [String: String] {
        [DataRootConstants.environmentKey: root.path]
    }

    func writeStandardDatabases(includeSeed: Bool = true) throws {
        try writeDatabases(schema: try Fixture.sql("schema"), includeSeed: includeSeed)
    }

    func writeDatabases(schema: String, includeSeed: Bool = true) throws {
        let seed = includeSeed ? try Fixture.sql("seed") : nil
        try writeDatabase(at: databaseURL, schema: schema, seed: seed)
        try writeDatabase(at: feedSettingsURL, schema: schema, seed: seed)
    }

    func writeDatabase(at url: URL, schema: String, seed: String?) throws {
        let writer = try SQLiteWriter(path: url.path)
        try writer.exec(schema)
        if let seed {
            try writer.exec(seed)
        }
    }

    func writeOPML(_ contents: String) throws {
        try contents.write(to: opmlURL, atomically: true, encoding: .utf8)
    }

    func writeStandardOPML() throws {
        try writeOPML(Fixture.standardOPML)
    }

    func prepare() throws -> ServerContext {
        try Startup.prepare(environment: environment)
    }

    func createStandardServerContext() throws -> ServerContext {
        try writeStandardDatabases()
        try writeStandardOPML()
        return try prepare()
    }

    func setDatabaseMtime(_ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: databaseURL.path)
    }

    func databaseMtime() throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw TestError(message: "无法读取测试库 mtime")
        }
        return date
    }
}

func makeCandidate(home: URL, relativePath: String, dbMtime: Date, directoryMtime: Date? = nil)
    throws
{
    let root = home.appendingPathComponent(relativePath, isDirectory: true)
    let onMyMac = root
        .appendingPathComponent("Accounts", isDirectory: true)
        .appendingPathComponent("OnMyMac", isDirectory: true)
    try FileManager.default.createDirectory(at: onMyMac, withIntermediateDirectories: true)
    let database = onMyMac.appendingPathComponent(DataRootConstants.databaseFileName)
    try Data("not-a-real-database".utf8).write(to: database)
    try FileManager.default.setAttributes(
        [.modificationDate: dbMtime], ofItemAtPath: database.path)
    if let directoryMtime {
        try FileManager.default.setAttributes(
            [.modificationDate: directoryMtime], ofItemAtPath: root.path)
    }
}

final class DataLocatorTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nnw-mcp-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func testSelectsCandidateWithNewerDatabaseMtime() throws {
        let home = try makeHome()
        defer { cleanup(home) }

        let activeRelative = DataRootConstants.activeRelativePath
        let legacyRelative = DataRootConstants.legacyContainerRelativePath
        try makeCandidate(
            home: home, relativePath: activeRelative,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_000))
        try makeCandidate(
            home: home, relativePath: legacyRelative,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_600))

        let selection = try DataLocator.locate(environment: [:], homeDirectory: home.path)
        let active = home.appendingPathComponent(activeRelative).standardizedFileURL.path
        let legacy = home.appendingPathComponent(legacyRelative).standardizedFileURL.path

        XCTAssertEqual(selection.selectedPath, legacy)
        XCTAssertTrue(selection.candidates.filter(\.selected).count == 1)
        XCTAssertEqual(selection.candidates.first(where: \.selected)?.path, legacy)
        XCTAssertFalse(selection.ambiguous)
        XCTAssertTrue(selection.candidates.contains { $0.path == active })
    }

    func testAmbiguousWhenDatabaseMtimesWithin300Seconds() throws {
        let home = try makeHome()
        defer { cleanup(home) }

        try makeCandidate(
            home: home, relativePath: DataRootConstants.activeRelativePath,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_000))
        try makeCandidate(
            home: home, relativePath: DataRootConstants.legacyContainerRelativePath,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_299))

        let selection = try DataLocator.locate(environment: [:], homeDirectory: home.path)
        XCTAssertTrue(selection.ambiguous)
        XCTAssertEqual(
            selection.selectedPath,
            home.appendingPathComponent(DataRootConstants.legacyContainerRelativePath)
                .standardizedFileURL.path)
    }

    func testDirectoryMtimeIsNotUsedForSelection() throws {
        let home = try makeHome()
        defer { cleanup(home) }

        // The active root directory is newer, but its DB is older.
        try makeCandidate(
            home: home, relativePath: DataRootConstants.activeRelativePath,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_000),
            directoryMtime: Date(timeIntervalSince1970: 1_800_000_000))
        try makeCandidate(
            home: home, relativePath: DataRootConstants.legacyContainerRelativePath,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_600),
            directoryMtime: Date(timeIntervalSince1970: 1_600_000_000))

        let selection = try DataLocator.locate(environment: [:], homeDirectory: home.path)
        XCTAssertEqual(
            selection.selectedPath,
            home.appendingPathComponent(DataRootConstants.legacyContainerRelativePath)
                .standardizedFileURL.path)
    }

    func testOverrideMissingRootFailsWithoutFallback() throws {
        let home = try makeHome()
        defer { cleanup(home) }
        try makeCandidate(
            home: home, relativePath: DataRootConstants.activeRelativePath,
            dbMtime: Date())

        let missing = home.appendingPathComponent("does-not-exist").path
        XCTAssertThrowsError(
            try DataLocator.locate(
                environment: [DataRootConstants.environmentKey: missing],
                homeDirectory: home.path)
        ) { error in
            guard let startupError = error as? StartupError else {
                return XCTFail("期望 StartupError，实际 \(error)")
            }
            XCTAssertEqual(startupError.code, 4)
            XCTAssertTrue(startupError.message.contains(missing))
        }
    }

    func testOverrideUsesOnlyThatRoot() throws {
        let home = try makeHome()
        defer { cleanup(home) }
        try makeCandidate(
            home: home, relativePath: DataRootConstants.activeRelativePath,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_000))
        let override = try TestRoot()
        try makeCandidate(
            home: override.base, relativePath: "Override", dbMtime: Date(timeIntervalSince1970: 1))

        let selection = try DataLocator.locate(
            environment: [DataRootConstants.environmentKey: override.base
                .appendingPathComponent("Override").path],
            homeDirectory: home.path)
        XCTAssertTrue(selection.isOverride)
        XCTAssertEqual(selection.candidates.count, 1)
        XCTAssertTrue(selection.candidates[0].selected)
        XCTAssertFalse(selection.ambiguous)
    }

    func testSingleExistingCandidateIsSelected() throws {
        let home = try makeHome()
        defer { cleanup(home) }
        try makeCandidate(
            home: home, relativePath: DataRootConstants.activeRelativePath,
            dbMtime: Date(timeIntervalSince1970: 1_700_000_000))

        let selection = try DataLocator.locate(environment: [:], homeDirectory: home.path)
        XCTAssertEqual(
            selection.selectedPath,
            home.appendingPathComponent(DataRootConstants.activeRelativePath)
                .standardizedFileURL.path)
        XCTAssertEqual(selection.candidates.count, 2)
        XCTAssertEqual(selection.candidates.filter(\.selected).count, 1)
        XCTAssertEqual(selection.candidates.filter(\.exists).count, 1)
    }
}
