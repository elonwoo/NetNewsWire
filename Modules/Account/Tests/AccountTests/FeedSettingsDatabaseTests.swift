//
//  FeedSettingsDatabaseTests.swift
//  AccountTests
//
//  Created by Brent Simmons on 8/2/26.
//

import Foundation
import SQLite3
import Testing
@testable import Account

struct FeedSettingsDatabaseTests {

	@Test func feedIDColumnIsUpdatable() {
		let database = makeDatabase()
		let feedURL = "https://example.com/feed.xml"
		let canonicalFeedID = "feed/\(feedURL)"

		database.ensureFeedExists(feedURL, feedID: feedURL)
		database.setString(canonicalFeedID, for: feedURL, column: .feedID)

		#expect(database.allRows()[feedURL]?.feedID == canonicalFeedID)
	}

	@Test func ensureFeedExistsDoesNotReplaceFeedID() {
		let database = makeDatabase()
		let feedURL = "https://example.com/feed.xml"
		let canonicalFeedID = "feed/\(feedURL)"

		database.ensureFeedExists(feedURL, feedID: canonicalFeedID)
		database.ensureFeedExists(feedURL, feedID: feedURL)

		#expect(database.allRows()[feedURL]?.feedID == canonicalFeedID)
	}

	@Test func aiTogglesDefaultToOn() {
		let database = makeDatabase()
		let feedURL = "https://example.com/feed.xml"

		database.ensureFeedExists(feedURL, feedID: feedURL)

		#expect(database.allRows()[feedURL]?.aiRewriteEnabled == true)
		#expect(database.allRows()[feedURL]?.aiTranslationEnabled == true)
	}

	@Test func aiTogglesRoundTripAcrossReopen() throws {
		let url = try makeOnDiskDatabasePath()
		defer {
			try? FileManager.default.removeItem(at: url)
		}
		let feedURL = "https://example.com/feed.xml"

		let database = FeedSettingsDatabase(databasePath: url.path)
		database.ensureFeedExists(feedURL, feedID: feedURL)
		database.setBool(false, for: feedURL, column: .aiRewriteEnabled)
		database.setBool(true, for: feedURL, column: .aiTranslationEnabled)
		#expect(database.allRows()[feedURL]?.aiRewriteEnabled == false)
		#expect(database.allRows()[feedURL]?.aiTranslationEnabled == true)

		let reopened = FeedSettingsDatabase(databasePath: url.path)
		#expect(reopened.allRows()[feedURL]?.aiRewriteEnabled == false)
		#expect(reopened.allRows()[feedURL]?.aiTranslationEnabled == true)
	}

	@Test func openingPreAIToggleDatabaseEnablesBothToggles() throws {
		let url = try makeOnDiskDatabasePath()
		defer {
			try? FileManager.default.removeItem(at: url)
		}
		try createLegacyDatabase(at: url.path, hasTranslationOnlyColumn: false)

		let database = FeedSettingsDatabase(databasePath: url.path)
		let row = database.allRows()["https://example.com/feed.xml"]

		#expect(row?.feedID == "legacy-feed")
		#expect(row?.aiRewriteEnabled == true)
		#expect(row?.aiTranslationEnabled == true)
	}

	@Test func legacyTranslationOnlyRowMigratesToRewriteOffTranslationOn() throws {
		let url = try makeOnDiskDatabasePath()
		defer {
			try? FileManager.default.removeItem(at: url)
		}
		try createLegacyDatabase(at: url.path, translationOnly: true)

		let database = FeedSettingsDatabase(databasePath: url.path)
		let row = database.allRows()["https://example.com/feed.xml"]

		#expect(row?.aiRewriteEnabled == false)
		#expect(row?.aiTranslationEnabled == true)
	}

	@Test func legacyZeroRowMigratesToBothTogglesOn() throws {
		let url = try makeOnDiskDatabasePath()
		defer {
			try? FileManager.default.removeItem(at: url)
		}
		try createLegacyDatabase(at: url.path, translationOnly: false)

		let database = FeedSettingsDatabase(databasePath: url.path)
		let row = database.allRows()["https://example.com/feed.xml"]

		#expect(row?.aiRewriteEnabled == true)
		#expect(row?.aiTranslationEnabled == true)
	}

	@Test func migrationIsNotReappliedOnReopen() throws {
		let url = try makeOnDiskDatabasePath()
		defer {
			try? FileManager.default.removeItem(at: url)
		}
		try createLegacyDatabase(at: url.path, translationOnly: true)
		let feedURL = "https://example.com/feed.xml"

		let database = FeedSettingsDatabase(databasePath: url.path)
		#expect(database.allRows()[feedURL]?.aiRewriteEnabled == false)
		database.setBool(true, for: feedURL, column: .aiRewriteEnabled)
		// setBool dispatches asynchronously; a synchronous read flushes the queue
		// so the reopen below cannot race the write.
		#expect(database.allRows()[feedURL]?.aiRewriteEnabled == true)

		let reopened = FeedSettingsDatabase(databasePath: url.path)
		#expect(reopened.allRows()[feedURL]?.aiRewriteEnabled == true)
		#expect(reopened.allRows()[feedURL]?.aiTranslationEnabled == true)
	}

	@Test func failedMigrationFallsBackToLegacyColumn() throws {
		let url = try makeOnDiskDatabasePath()
		defer {
			try? FileManager.default.removeItem(at: url)
		}
		try createLegacyDatabase(at: url.path, translationOnly: true, blocksUpdates: true)
		let feedURL = "https://example.com/feed.xml"

		let database = FeedSettingsDatabase(databasePath: url.path)
		// The UPDATE that converts the legacy flag is blocked, so the whole
		// migration rolls back and reads fall back to the legacy column.
		#expect(database.allRows()[feedURL]?.aiRewriteEnabled == false)
		#expect(database.allRows()[feedURL]?.aiTranslationEnabled == true)

		// Writes are skipped while the schema is unavailable, without crashing.
		database.setBool(true, for: feedURL, column: .aiRewriteEnabled)
		#expect(database.allRows()[feedURL]?.aiRewriteEnabled == false)
	}

	private func makeDatabase() -> FeedSettingsDatabase {
		FeedSettingsDatabase(databasePath: ":memory:")
	}

	private func makeOnDiskDatabasePath() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory.appendingPathComponent("feedSettings.sqlite")
	}

	/// Creates the schema from before the two AI toggle columns existed, with one
	/// row. Optionally keeps the legacy `aiTranslationOnly` column and blocks all
	/// updates so the migration cannot finish.
	private func createLegacyDatabase(at path: String, hasTranslationOnlyColumn: Bool = true, translationOnly: Bool = false, blocksUpdates: Bool = false) throws {
		var handle: OpaquePointer?
		guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
			sqlite3_close(handle)
			throw SQLiteError()
		}
		defer {
			sqlite3_close(handle)
		}

		let legacyColumn = hasTranslationOnlyColumn ? ", aiTranslationOnly INTEGER NOT NULL DEFAULT 0" : ""
		let insertColumns = hasTranslationOnlyColumn ? "feedURL, feedID, aiTranslationOnly" : "feedURL, feedID"
		let insertValues = hasTranslationOnlyColumn ? "'https://example.com/feed.xml', 'legacy-feed', \(translationOnly ? 1 : 0)" : "'https://example.com/feed.xml', 'legacy-feed'"
		var sql = """
		CREATE TABLE feedSettings (feedURL TEXT PRIMARY KEY, feedID TEXT NOT NULL DEFAULT '', homePageURL TEXT, iconURL TEXT, faviconURL TEXT, editedName TEXT, contentHash TEXT, newArticleNotificationsEnabled INTEGER NOT NULL DEFAULT 0, readerViewAlwaysEnabled INTEGER NOT NULL DEFAULT 0, authors TEXT, conditionalGetInfoLastModified TEXT, conditionalGetInfoEtag TEXT, conditionalGetInfoDate REAL, cacheControlInfoDateCreated REAL, cacheControlInfoMaxAge REAL, externalID TEXT, folderRelationship TEXT, lastCheckDate REAL, lastResponseCode INTEGER\(legacyColumn));
		INSERT INTO feedSettings (\(insertColumns)) VALUES (\(insertValues));
		"""
		if blocksUpdates {
			sql += """
			CREATE TRIGGER blockUpdates BEFORE UPDATE ON feedSettings BEGIN SELECT RAISE(ABORT, 'blocked'); END;
			"""
		}
		guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
			throw SQLiteError()
		}
	}
}

private struct SQLiteError: Error {
}
