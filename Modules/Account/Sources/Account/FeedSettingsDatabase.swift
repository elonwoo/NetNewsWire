//
//  FeedSettingsDatabase.swift
//  Account
//
//  Created by Brent Simmons on 3/6/26.
//

import Foundation
import RSCore
import os
import RSDatabase
import RSDatabaseObjC
import RSWeb
import Articles

final class FeedSettingsDatabase: Sendable {
	enum Column: String {
		case feedID
		case homePageURL
		case iconURL
		case faviconURL
		case editedName
		case contentHash
		case newArticleNotificationsEnabled
		case readerViewAlwaysEnabled
		case aiRewriteEnabled
		case aiTranslationEnabled
		case aiLanguageOverride
		case authors
		case conditionalGetInfoLastModified
		case conditionalGetInfoEtag
		case conditionalGetInfoDate
		case cacheControlInfoDateCreated
		case cacheControlInfoMaxAge
		case externalID
		case folderRelationship
		case lastCheckDate
		case lastResponseCode
	}

	struct Row {
		let feedID: String
		let homePageURL: String?
		let iconURL: String?
		let faviconURL: String?
		let editedName: String?
		let contentHash: String?
		let newArticleNotificationsEnabled: Bool
		let readerViewAlwaysEnabled: Bool
		let aiRewriteEnabled: Bool
		let aiTranslationEnabled: Bool
		let aiLanguageOverride: Bool
		let authors: Set<Author>?
		let conditionalGetInfo: HTTPConditionalGetInfo?
		let conditionalGetInfoDate: Date?
		let cacheControlInfo: CacheControlInfo?
		let externalID: String?
		let folderRelationship: [String: String]?
		let lastCheckDate: Date?
		let lastResponseCode: Int?
	}

	struct AIState: Equatable {
		let rewriteEnabled: Bool
		let translationEnabled: Bool
		let languageOverride: Bool
	}

	let databasePath: String

	/// False when the two AI toggle columns could not be added. Row parsing then
	/// falls back to the legacy `aiTranslationOnly` column, writes are skipped,
	/// and the next launch retries the migration.
	private let isAIToggleSchemaAvailable: Bool
	private let hasLegacyAITranslationColumn: Bool

	nonisolated(unsafe) private let database: FMDatabase // Used on serial dispatch queue only
	private let serialDispatchQueue: DispatchQueue
	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "FeedSettingsDatabase")

	init(databasePath: String) {
		self.databasePath = databasePath
		self.serialDispatchQueue = DispatchQueue(label: "FeedSettingsDatabase")
		self.database = FMDatabase.openAndSetUpDatabase(path: databasePath)
		var schemaAvailable = true
		var hasLegacyColumn = false
		serialDispatchQueue.sync { [database] in
			database.runCreateStatements(Self.tableCreationStatements)
			if !database.columnExists("lastResponseCode", inTableWithName: "feedSettings") {
				database.executeStatements("ALTER TABLE feedSettings ADD COLUMN lastResponseCode INTEGER;")
			}
			if !database.columnExists("aiLanguageOverride", inTableWithName: "feedSettings") {
				database.executeStatements("ALTER TABLE feedSettings ADD COLUMN aiLanguageOverride INTEGER NOT NULL DEFAULT 0;")
			}
			schemaAvailable = Self.migrateAIToggleColumns(in: database)
			hasLegacyColumn = database.columnExists("aiTranslationOnly", inTableWithName: "feedSettings")
		}
		self.isAIToggleSchemaAvailable = schemaAvailable
		self.hasLegacyAITranslationColumn = hasLegacyColumn
		vacuumIfNeeded()
	}

	func vacuum() async {
		await withCheckedContinuation { continuation in
			serialDispatchQueue.async {
				self.database.vacuum()
				continuation.resume()
			}
		}
	}

	func vacuumIfNeeded() {
		serialDispatchQueue.async {
			self.database.vacuumIfNeeded()
		}
	}

	var isEmpty: Bool {
		serialDispatchQueue.sync {
			guard let resultSet = self.database.executeQuery("SELECT 1 FROM feedSettings LIMIT 1;", withArgumentsIn: []) else {
				return true
			}
			defer {
				resultSet.close()
			}
			return !resultSet.next()
		}
	}

	// MARK: - Feed Existence

	func ensureFeedExists(_ feedURL: String, feedID: String) {
		serialDispatchQueue.async {
			self.database.executeUpdate("INSERT OR IGNORE INTO feedSettings (feedURL, feedID) VALUES (?, ?);", withArgumentsIn: [feedURL, feedID])
		}
	}

	// MARK: - Insert Row

	func insertRow(_ feedURL: String, _ columnValues: [Column: Any]) {
		var dictionary = DatabaseDictionary()
		dictionary["feedURL"] = feedURL
		for (column, value) in columnValues {
			dictionary[column.rawValue] = value
		}
		nonisolated(unsafe) let capturedDictionary = dictionary
		serialDispatchQueue.async {
			self.database.insertRow(capturedDictionary, insertType: .orReplace, tableName: "feedSettings")
		}
	}

	// MARK: - Fetch Rows

	func allRows() -> [String: Row] {
		serialDispatchQueue.sync {
			guard let resultSet = self.database.executeQuery("SELECT * FROM feedSettings;", withArgumentsIn: []) else {
				return [:]
			}
			defer {
				resultSet.close()
			}

			var rows = [String: Row]()
			while resultSet.next() {
				if let feedURL = resultSet.swiftString(forColumn: "feedURL") {
					rows[feedURL] = self.row(from: resultSet)
				}
			}
			return rows
		}
	}

	// MARK: - String

	func setString(_ value: String?, for feedURL: String, column: Column) {
		let name = column.rawValue
		serialDispatchQueue.async {
			if let value {
				self.database.executeUpdate("UPDATE feedSettings SET \(name) = ? WHERE feedURL = ?;", withArgumentsIn: [value, feedURL])
			} else {
				self.database.executeUpdate("UPDATE feedSettings SET \(name) = NULL WHERE feedURL = ?;", withArgumentsIn: [feedURL])
			}
		}
	}

	// MARK: - Bool

	func setBool(_ value: Bool, for feedURL: String, column: Column) {
		guard canWrite(column) else {
			return
		}
		let name = column.rawValue
		serialDispatchQueue.async {
			self.database.executeUpdate("UPDATE feedSettings SET \(name) = ? WHERE feedURL = ?;", withArgumentsIn: [value, feedURL])
		}
	}

	// MARK: - AI Language Detection

	/// Applies the automatic Chinese-feed result only while the user has not
	/// overridden the language setting. Returns true when a row matched, which
	/// means the switches were written to off.
	@discardableResult
	func applyAutomaticChineseOff(for feedURL: String) -> Bool {
		serialDispatchQueue.sync {
			let updated = self.database.executeUpdate("UPDATE feedSettings SET aiRewriteEnabled = 0, aiTranslationEnabled = 0 WHERE feedURL = ? AND aiLanguageOverride = 0;", withArgumentsIn: [feedURL])
			return updated && self.database.changes() > 0
		}
	}

	/// Writes the user's override and the switches they turned on in one UPDATE.
	/// A nil switch is left at the value read from the database inside this same
	/// serial queue, so a value the user did not touch cannot go stale. Returns
	/// the stored state afterwards.
	func setAIEnabledByUser(for feedURL: String, rewriteEnabled: Bool?, translationEnabled: Bool?) -> AIState? {
		serialDispatchQueue.sync {
			var clauses = ["aiLanguageOverride = 1"]
			var arguments: [Any] = []
			if let rewriteEnabled {
				clauses.append("aiRewriteEnabled = ?")
				arguments.append(rewriteEnabled)
			}
			if let translationEnabled {
				clauses.append("aiTranslationEnabled = ?")
				arguments.append(translationEnabled)
			}
			arguments.append(feedURL)
			let sql = "UPDATE feedSettings SET \(clauses.joined(separator: ", ")) WHERE feedURL = ?;"
			guard self.database.executeUpdate(sql, withArgumentsIn: arguments) else {
				return nil
			}
			return self.readAIState(for: feedURL)
		}
	}

	// MARK: - Int

	func setInt(_ value: Int?, for feedURL: String, column: Column) {
		let name = column.rawValue
		serialDispatchQueue.async {
			if let value {
				self.database.executeUpdate("UPDATE feedSettings SET \(name) = ? WHERE feedURL = ?;", withArgumentsIn: [value, feedURL])
			} else {
				self.database.executeUpdate("UPDATE feedSettings SET \(name) = NULL WHERE feedURL = ?;", withArgumentsIn: [feedURL])
			}
		}
	}

	// MARK: - Date

	func setDate(_ value: Date?, for feedURL: String, column: Column) {
		let name = column.rawValue
		serialDispatchQueue.async {
			if let value {
				self.database.executeUpdate("UPDATE feedSettings SET \(name) = ? WHERE feedURL = ?;", withArgumentsIn: [value.timeIntervalSinceReferenceDate, feedURL])
			} else {
				self.database.executeUpdate("UPDATE feedSettings SET \(name) = NULL WHERE feedURL = ?;", withArgumentsIn: [feedURL])
			}
		}
	}

	// MARK: - Compound Types

	func setConditionalGetInfo(_ info: HTTPConditionalGetInfo?, for feedURL: String) {
		serialDispatchQueue.async {
			if let info {
				self.database.executeUpdate("UPDATE feedSettings SET conditionalGetInfoLastModified = ?, conditionalGetInfoEtag = ? WHERE feedURL = ?;", withArgumentsIn: [info.lastModified as Any, info.etag as Any, feedURL])
			} else {
				self.database.executeUpdate("UPDATE feedSettings SET conditionalGetInfoLastModified = NULL, conditionalGetInfoEtag = NULL WHERE feedURL = ?;", withArgumentsIn: [feedURL])
			}
		}
	}

	func setCacheControlInfo(_ info: CacheControlInfo?, for feedURL: String) {
		serialDispatchQueue.async {
			if let info {
				self.database.executeUpdate("UPDATE feedSettings SET cacheControlInfoDateCreated = ?, cacheControlInfoMaxAge = ? WHERE feedURL = ?;", withArgumentsIn: [info.dateCreated.timeIntervalSinceReferenceDate, info.maxAge, feedURL])
			} else {
				self.database.executeUpdate("UPDATE feedSettings SET cacheControlInfoDateCreated = NULL, cacheControlInfoMaxAge = NULL WHERE feedURL = ?;", withArgumentsIn: [feedURL])
			}
		}
	}

	func setAuthors(_ authors: Set<Author>?, for feedURL: String) {
		serialDispatchQueue.async {
			if let authors {
				let jsonString = authors.json()
				self.database.executeUpdate("UPDATE feedSettings SET authors = ? WHERE feedURL = ?;", withArgumentsIn: [jsonString as Any, feedURL])
			} else {
				self.database.executeUpdate("UPDATE feedSettings SET authors = NULL WHERE feedURL = ?;", withArgumentsIn: [feedURL])
			}
		}
	}

	func setFolderRelationship(_ relationship: [String: String]?, for feedURL: String) {
		serialDispatchQueue.async {
			if let relationship {
				if let data = try? JSONSerialization.data(withJSONObject: relationship), let jsonString = String(data: data, encoding: .utf8) {
					self.database.executeUpdate("UPDATE feedSettings SET folderRelationship = ? WHERE feedURL = ?;", withArgumentsIn: [jsonString, feedURL])
				}
			} else {
				self.database.executeUpdate("UPDATE feedSettings SET folderRelationship = NULL WHERE feedURL = ?;", withArgumentsIn: [feedURL])
			}
		}
	}

	// MARK: - Deletion

	func deleteSettings(for feedURL: String) {
		serialDispatchQueue.async {
			self.database.executeUpdate("DELETE FROM feedSettings WHERE feedURL = ?;", withArgumentsIn: [feedURL])
		}
	}

	// MARK: - Cleanup on launch

	func deleteSettingsForFeedsNotIn(_ feedURLs: Set<String>) {
		guard !feedURLs.isEmpty else {
			return
		}

		let feedURLsArray = Array(feedURLs)
		serialDispatchQueue.async {
			let placeholders = NSString.rs_SQLValueList(withPlaceholders: UInt(feedURLsArray.count))
			let sql = "DELETE FROM feedSettings WHERE feedURL NOT IN \(placeholders);"
			self.database.executeUpdate(sql, withArgumentsIn: feedURLsArray)

			#if DEBUG
			let numberOfRowChanges: Int32 = self.database.changes()
			if numberOfRowChanges > 0 {
				Self.logger.info("FeedSettingsDatabase: deleteSettingsForFeedsNotIn: deleted \(numberOfRowChanges) orphaned feed settings")
			}
			#endif
		}
	}
}

// MARK: - Private

private extension FeedSettingsDatabase {

	static let tableCreationStatements = """
	CREATE TABLE IF NOT EXISTS feedSettings (feedURL TEXT PRIMARY KEY, feedID TEXT NOT NULL DEFAULT '', homePageURL TEXT, iconURL TEXT, faviconURL TEXT, editedName TEXT, contentHash TEXT, newArticleNotificationsEnabled INTEGER NOT NULL DEFAULT 0, readerViewAlwaysEnabled INTEGER NOT NULL DEFAULT 0, aiRewriteEnabled INTEGER NOT NULL DEFAULT 1, aiTranslationEnabled INTEGER NOT NULL DEFAULT 1, aiLanguageOverride INTEGER NOT NULL DEFAULT 0, authors TEXT, conditionalGetInfoLastModified TEXT, conditionalGetInfoEtag TEXT, conditionalGetInfoDate REAL, cacheControlInfoDateCreated REAL, cacheControlInfoMaxAge REAL, externalID TEXT, folderRelationship TEXT, lastCheckDate REAL, lastResponseCode INTEGER);
	"""

	/// Adds the two AI toggle columns and converts the legacy single flag in one
	/// transaction. Returns false on failure so the caller can fall back to the
	/// legacy column and retry on the next launch.
	static func migrateAIToggleColumns(in database: FMDatabase) -> Bool {
		let hasRewriteColumn = database.columnExists(Column.aiRewriteEnabled.rawValue, inTableWithName: "feedSettings")
		let hasTranslationColumn = database.columnExists(Column.aiTranslationEnabled.rawValue, inTableWithName: "feedSettings")
		guard !hasRewriteColumn || !hasTranslationColumn else {
			return true
		}
		guard database.beginTransaction() else {
			Self.logger.error("FeedSettingsDatabase: could not start the AI toggle migration transaction")
			return false
		}

		var succeeded = true
		if !hasRewriteColumn {
			if !database.executeStatements("ALTER TABLE feedSettings ADD COLUMN aiRewriteEnabled INTEGER NOT NULL DEFAULT 1;") {
				succeeded = false
			}
		}
		if succeeded && !hasTranslationColumn {
			if !database.executeStatements("ALTER TABLE feedSettings ADD COLUMN aiTranslationEnabled INTEGER NOT NULL DEFAULT 1;") {
				succeeded = false
			}
		}
		if succeeded && database.columnExists("aiTranslationOnly", inTableWithName: "feedSettings") {
			let sql = """
			UPDATE feedSettings SET
				aiRewriteEnabled = CASE WHEN COALESCE(aiTranslationOnly, 0) = 1 THEN 0 ELSE 1 END,
				aiTranslationEnabled = 1;
			"""
			if !database.executeStatements(sql) {
				succeeded = false
			}
		}

		guard succeeded else {
			database.rollback()
			Self.logger.error("FeedSettingsDatabase: AI toggle migration failed; using the legacy column until the next launch")
			return false
		}
		guard database.commit() else {
			database.rollback()
			Self.logger.error("FeedSettingsDatabase: could not commit the AI toggle migration")
			return false
		}
		return true
	}

	/// Must run on the serial dispatch queue.
	func readAIState(for feedURL: String) -> AIState? {
		let sql = "SELECT aiRewriteEnabled, aiTranslationEnabled, aiLanguageOverride FROM feedSettings WHERE feedURL = ? LIMIT 1;"
		guard let resultSet = database.executeQuery(sql, withArgumentsIn: [feedURL]) else {
			return nil
		}
		defer {
			resultSet.close()
		}
		guard resultSet.next() else {
			return nil
		}
		return AIState(
			rewriteEnabled: resultSet.bool(forColumn: Column.aiRewriteEnabled.rawValue),
			translationEnabled: resultSet.bool(forColumn: Column.aiTranslationEnabled.rawValue),
			languageOverride: resultSet.bool(forColumn: Column.aiLanguageOverride.rawValue)
		)
	}

	func canWrite(_ column: Column) -> Bool {
		switch column {
		case .aiRewriteEnabled, .aiTranslationEnabled:
			guard isAIToggleSchemaAvailable else {
				Self.logger.error("FeedSettingsDatabase: AI toggle schema unavailable; skipped \(column.rawValue, privacy: .public) write")
				return false
			}
			return true
		default:
			return true
		}
	}

	func row(from resultSet: FMResultSet) -> Row {
		let lastModified = resultSet.swiftString(forColumn: Column.conditionalGetInfoLastModified.rawValue)
		let etag = resultSet.swiftString(forColumn: Column.conditionalGetInfoEtag.rawValue)

		var conditionalGetInfoDate: Date?
		if !resultSet.columnIsNull(Column.conditionalGetInfoDate.rawValue) {
			conditionalGetInfoDate = Date(timeIntervalSinceReferenceDate: resultSet.double(forColumn: Column.conditionalGetInfoDate.rawValue))
		}

		var cacheControlInfo: CacheControlInfo?
		if !resultSet.columnIsNull(Column.cacheControlInfoDateCreated.rawValue) && !resultSet.columnIsNull(Column.cacheControlInfoMaxAge.rawValue) {
			let dateCreated = Date(timeIntervalSinceReferenceDate: resultSet.double(forColumn: Column.cacheControlInfoDateCreated.rawValue))
			let maxAge = resultSet.double(forColumn: Column.cacheControlInfoMaxAge.rawValue)
			cacheControlInfo = CacheControlInfo(dateCreated: dateCreated, maxAge: maxAge)
		}

		var authors: Set<Author>?
		if let authorsData = resultSet.data(forColumn: Column.authors.rawValue) {
			authors = Author.authorsWithJSON(authorsData)
		}

		var folderRelationship: [String: String]?
		if let folderData = resultSet.data(forColumn: Column.folderRelationship.rawValue) {
			folderRelationship = try? JSONSerialization.jsonObject(with: folderData) as? [String: String]
		}

		var lastCheckDate: Date?
		if !resultSet.columnIsNull(Column.lastCheckDate.rawValue) {
			lastCheckDate = Date(timeIntervalSinceReferenceDate: resultSet.double(forColumn: Column.lastCheckDate.rawValue))
		}

		var lastResponseCode: Int?
		if !resultSet.columnIsNull(Column.lastResponseCode.rawValue) {
			lastResponseCode = Int(resultSet.int(forColumn: Column.lastResponseCode.rawValue))
		}

		let aiToggles = aiToggleValues(from: resultSet)

		return Row(
			feedID: resultSet.swiftString(forColumn: Column.feedID.rawValue) ?? "",
			homePageURL: resultSet.swiftString(forColumn: Column.homePageURL.rawValue),
			iconURL: resultSet.swiftString(forColumn: Column.iconURL.rawValue),
			faviconURL: resultSet.swiftString(forColumn: Column.faviconURL.rawValue),
			editedName: resultSet.swiftString(forColumn: Column.editedName.rawValue),
			contentHash: resultSet.swiftString(forColumn: Column.contentHash.rawValue),
			newArticleNotificationsEnabled: resultSet.bool(forColumn: Column.newArticleNotificationsEnabled.rawValue),
			readerViewAlwaysEnabled: resultSet.bool(forColumn: Column.readerViewAlwaysEnabled.rawValue),
			aiRewriteEnabled: aiToggles.rewrite,
			aiTranslationEnabled: aiToggles.translation,
			aiLanguageOverride: resultSet.bool(forColumn: Column.aiLanguageOverride.rawValue),
			authors: authors,
			conditionalGetInfo: HTTPConditionalGetInfo(lastModified: lastModified, etag: etag),
			conditionalGetInfoDate: conditionalGetInfoDate,
			cacheControlInfo: cacheControlInfo,
			externalID: resultSet.swiftString(forColumn: Column.externalID.rawValue),
			folderRelationship: folderRelationship,
			lastCheckDate: lastCheckDate,
			lastResponseCode: lastResponseCode
		)
	}

	/// Reads the two AI toggles from the migrated columns when they exist. If the
	/// migration failed, the legacy single flag still describes the intent:
	/// translation-only meant rewrite off and translation on.
	func aiToggleValues(from resultSet: FMResultSet) -> (rewrite: Bool, translation: Bool) {
		if isAIToggleSchemaAvailable {
			return (
				rewrite: resultSet.bool(forColumn: Column.aiRewriteEnabled.rawValue),
				translation: resultSet.bool(forColumn: Column.aiTranslationEnabled.rawValue)
			)
		}
		if hasLegacyAITranslationColumn {
			return (rewrite: !resultSet.bool(forColumn: "aiTranslationOnly"), translation: true)
		}
		return (rewrite: true, translation: true)
	}
}
