//
//  FeedSettingsAIStateTests.swift
//  AccountTests
//

import Foundation
import SQLite3
import Testing
@testable import Account

@Suite(.serialized)
@MainActor
struct FeedSettingsAIStateTests {

	private let feedURL = "https://example.com/feed.xml"
	private let feedID = "feed/example"

	// MARK: - Migration

	@Test func legacyDatabaseUpgradesWithOverrideOff() throws {
		let url = try makeDatabasePath()
		defer {
			try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
		}
		try createLegacyDatabase(at: url.path)
		let database = FeedSettingsDatabase(databasePath: url.path)

		let row = database.allRows()[feedURL]
		#expect(row?.aiRewriteEnabled == true)
		#expect(row?.aiTranslationEnabled == true)
		#expect(row?.aiLanguageOverride == false)
	}

	// MARK: - Automatic detection

	@Test func automaticChineseOffWritesBothSwitchesInOneUpdateAndNotifies() throws {
		let harness = try makeHarness()
		defer {
			harness.cleanup()
		}
		try harness.installUpdateCounter()
		let recorder = SettingChangeRecorder(object: harness.settings)
		defer {
			recorder.stop()
		}

		let changed = harness.settings.applyAutomaticChineseOff()

		#expect(changed)
		#expect(harness.settings.aiRewriteEnabled == false)
		#expect(harness.settings.aiTranslationEnabled == false)
		#expect(harness.settings.aiLanguageOverride == false)
		#expect(harness.database.allRows()[feedURL]?.aiRewriteEnabled == false)
		#expect(harness.database.allRows()[feedURL]?.aiTranslationEnabled == false)
		#expect(harness.database.allRows()[feedURL]?.aiLanguageOverride == false)
		#expect(try harness.updateCount() == 1)
		#expect(recorder.count(.aiRewriteEnabled) == 1)
		#expect(recorder.count(.aiTranslationEnabled) == 1)
	}

	@Test func automaticChineseOffDoesNothingAfterAUserOverride() throws {
		let harness = try makeHarness()
		defer {
			harness.cleanup()
		}
		let recorder = SettingChangeRecorder(object: harness.settings)
		defer {
			recorder.stop()
		}
		// User turns rewrite off, then back on: the on direction sets the override.
		harness.settings.aiRewriteEnabled = false
		harness.settings.setAIEnabledByUser(rewriteEnabled: true, translationEnabled: harness.settings.aiTranslationEnabled)
		#expect(harness.settings.aiLanguageOverride)
		try harness.installUpdateCounter()
		recorder.reset()

		let changed = harness.settings.applyAutomaticChineseOff()

		#expect(!changed)
		#expect(harness.settings.aiRewriteEnabled)
		#expect(harness.settings.aiTranslationEnabled)
		#expect(harness.settings.aiLanguageOverride)
		#expect(try harness.updateCount() == 0)
		#expect(recorder.count(.aiRewriteEnabled) == 0)
		#expect(recorder.count(.aiTranslationEnabled) == 0)
	}

	// MARK: - User override

	@Test func userEnableWritesOverrideAndSwitchInOneUpdate() throws {
		let harness = try makeHarness()
		defer {
			harness.cleanup()
		}
		harness.settings.aiRewriteEnabled = false
		try harness.installUpdateCounter()
		let recorder = SettingChangeRecorder(object: harness.settings)
		defer {
			recorder.stop()
		}

		harness.settings.setAIEnabledByUser(rewriteEnabled: true, translationEnabled: harness.settings.aiTranslationEnabled)

		#expect(harness.settings.aiRewriteEnabled)
		#expect(harness.settings.aiTranslationEnabled)
		#expect(harness.settings.aiLanguageOverride)
		#expect(harness.database.allRows()[feedURL]?.aiRewriteEnabled == true)
		#expect(harness.database.allRows()[feedURL]?.aiLanguageOverride == true)
		#expect(try harness.updateCount() == 1)
		#expect(recorder.count(.aiRewriteEnabled) == 1)
	}

	@Test func untouchedSwitchKeepsTheValueStoredByAutomaticOff() throws {
		let harness = try makeHarness()
		defer {
			harness.cleanup()
		}
		harness.settings.applyAutomaticChineseOff()
		#expect(harness.settings.aiTranslationEnabled == false)
		try harness.installUpdateCounter()

		// The user only turns rewrite on; translation is passed as its current
		// value and must stay at the automatic-off result.
		harness.settings.setAIEnabledByUser(rewriteEnabled: true, translationEnabled: harness.settings.aiTranslationEnabled)

		#expect(harness.settings.aiRewriteEnabled)
		#expect(harness.settings.aiTranslationEnabled == false)
		#expect(harness.settings.aiLanguageOverride)
		#expect(harness.database.allRows()[feedURL]?.aiRewriteEnabled == true)
		#expect(harness.database.allRows()[feedURL]?.aiTranslationEnabled == false)
		#expect(try harness.updateCount() == 1)
	}

	@Test func untouchedSwitchIsReadFromTheDatabaseNotFromMemory() throws {
		let harness = try makeHarness()
		defer {
			harness.cleanup()
		}
		harness.settings.applyAutomaticChineseOff()
		#expect(harness.settings.aiTranslationEnabled == false)
		// Write the untouched switch behind the settings object's back, so its
		// in-memory value is stale.
		try harness.setTranslationEnabledInDatabase(true)
		try harness.installUpdateCounter()

		harness.settings.setAIEnabledByUser(rewriteEnabled: true, translationEnabled: false)

		#expect(harness.settings.aiRewriteEnabled)
		#expect(harness.settings.aiTranslationEnabled)
		#expect(harness.settings.aiLanguageOverride)
		#expect(try harness.updateCount() == 1)
	}

	@Test func userDisableDoesNotSetTheOverride() throws {
		let harness = try makeHarness()
		defer {
			harness.cleanup()
		}

		harness.settings.aiRewriteEnabled = false

		#expect(harness.settings.aiLanguageOverride == false)
		#expect(harness.database.allRows()[feedURL]?.aiLanguageOverride == false)
		#expect(harness.database.allRows()[feedURL]?.aiRewriteEnabled == false)
	}

	@Test func userOverrideLandedFirstWinsOverTheAutomaticResult() throws {
		let harness = try makeHarness()
		defer {
			harness.cleanup()
		}
		harness.settings.aiRewriteEnabled = false
		harness.settings.setAIEnabledByUser(rewriteEnabled: true, translationEnabled: harness.settings.aiTranslationEnabled)

		let changed = harness.settings.applyAutomaticChineseOff()

		#expect(!changed)
		#expect(harness.settings.aiLanguageOverride)
		#expect(harness.settings.aiRewriteEnabled)
	}
}

// MARK: - Harness

@MainActor
private struct FeedSettingsAIStateHarness {

	let folder: URL
	let databasePath: String
	let feedURL: String
	let database: FeedSettingsDatabase
	let settings: FeedSettings

	func cleanup() {
		try? FileManager.default.removeItem(at: folder)
	}

	func installUpdateCounter() throws {
		// Flush queued writes before a second connection touches the file.
		_ = database.allRows()
		try executeDatabaseSQL("""
		CREATE TABLE IF NOT EXISTS write_log (n INTEGER);
		CREATE TRIGGER IF NOT EXISTS log_settings_update AFTER UPDATE ON feedSettings BEGIN INSERT INTO write_log (n) VALUES (1); END;
		""")
	}

	func updateCount() throws -> Int {
		var handle: OpaquePointer?
		guard sqlite3_open(databasePath, &handle) == SQLITE_OK, let handle else {
			throw FeedSettingsAIStateError()
		}
		defer {
			sqlite3_close(handle)
		}
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM write_log;", -1, &statement, nil) == SQLITE_OK, let statement else {
			throw FeedSettingsAIStateError()
		}
		defer {
			sqlite3_finalize(statement)
		}
		guard sqlite3_step(statement) == SQLITE_ROW else {
			throw FeedSettingsAIStateError()
		}
		return Int(sqlite3_column_int(statement, 0))
	}

	func setTranslationEnabledInDatabase(_ enabled: Bool) throws {
		try executeDatabaseSQL("UPDATE feedSettings SET aiTranslationEnabled = \(enabled ? 1 : 0) WHERE feedURL = '\(feedURL)';")
	}

	private func executeDatabaseSQL(_ sql: String) throws {
		var handle: OpaquePointer?
		guard sqlite3_open(databasePath, &handle) == SQLITE_OK, let handle else {
			throw FeedSettingsAIStateError()
		}
		defer {
			sqlite3_close(handle)
		}
		guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
			throw FeedSettingsAIStateError()
		}
	}
}

private extension FeedSettingsAIStateTests {

	func makeDatabasePath() throws -> URL {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeedSettingsAIStateTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder.appendingPathComponent("FeedSettings.db")
	}

	func makeHarness() throws -> FeedSettingsAIStateHarness {
		let url = try makeDatabasePath()
		let database = FeedSettingsDatabase(databasePath: url.path)
		database.ensureFeedExists(feedURL, feedID: feedID)
		// Flush the serial queue before the settings are built and before a second
		// connection creates the write counter.
		_ = database.allRows()
		let settings = FeedSettings(feedURL: feedURL, feedID: feedID, database: database)
		return FeedSettingsAIStateHarness(
			folder: url.deletingLastPathComponent(),
			databasePath: url.path,
			feedURL: feedURL,
			database: database,
			settings: settings
		)
	}

	/// A database from before the language override column existed.
	func createLegacyDatabase(at path: String) throws {
		var handle: OpaquePointer?
		guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
			throw FeedSettingsAIStateError()
		}
		defer {
			sqlite3_close(handle)
		}
		let sql = """
		CREATE TABLE feedSettings (feedURL TEXT PRIMARY KEY, feedID TEXT NOT NULL DEFAULT '', homePageURL TEXT, iconURL TEXT, faviconURL TEXT, editedName TEXT, contentHash TEXT, newArticleNotificationsEnabled INTEGER NOT NULL DEFAULT 0, readerViewAlwaysEnabled INTEGER NOT NULL DEFAULT 0, aiRewriteEnabled INTEGER NOT NULL DEFAULT 1, aiTranslationEnabled INTEGER NOT NULL DEFAULT 1, authors TEXT, conditionalGetInfoLastModified TEXT, conditionalGetInfoEtag TEXT, conditionalGetInfoDate REAL, cacheControlInfoDateCreated REAL, cacheControlInfoMaxAge REAL, externalID TEXT, folderRelationship TEXT, lastCheckDate REAL, lastResponseCode INTEGER);
		INSERT INTO feedSettings (feedURL, feedID) VALUES ('\(feedURL)', 'legacy-feed');
		"""
		guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
			throw FeedSettingsAIStateError()
		}
	}
}

private final class SettingChangeRecorder: @unchecked Sendable {

	private let lock = NSLock()
	private var counts: [String: Int] = [:]
	private var token: NSObjectProtocol?

	@MainActor
	init(object: AnyObject) {
		let settingKey = Feed.SettingUserInfoKey
		token = NotificationCenter.default.addObserver(forName: .feedSettingDidChange, object: object, queue: nil) { [weak self] notification in
			guard let key = notification.userInfo?[settingKey] as? Feed.SettingKey else {
				return
			}
			self?.record(key)
		}
	}

	func stop() {
		if let token {
			NotificationCenter.default.removeObserver(token)
			self.token = nil
		}
	}

	func reset() {
		lock.lock()
		counts.removeAll()
		lock.unlock()
	}

	func count(_ key: Feed.SettingKey) -> Int {
		let name = Self.name(for: key)
		lock.lock()
		defer {
			lock.unlock()
		}
		return counts[name, default: 0]
	}

	private func record(_ key: Feed.SettingKey) {
		let name = Self.name(for: key)
		lock.lock()
		counts[name, default: 0] += 1
		lock.unlock()
	}

	private static func name(for key: Feed.SettingKey) -> String {
		switch key {
		case .aiRewriteEnabled:
			return "rewrite"
		case .aiTranslationEnabled:
			return "translation"
		default:
			return "other"
		}
	}
}

private struct FeedSettingsAIStateError: Error {
}
