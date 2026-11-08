//
//  Store.swift
//  AI
//

import Foundation
import RSDatabase
import RSDatabaseObjC

public protocol AIStore: Sendable {
	func translation(for articleID: String) async throws -> Translation?
	func saveTranslation(_ translation: Translation) async throws
	func saveTitleTranslation(articleID: String, titleZh: String, model: String, contentHash: String, at date: Date) async throws
	func rewrite(for articleID: String) async throws -> Rewrite?
	func saveRewrite(_ rewrite: Rewrite) async throws
	func chatMessages(for articleID: String) async throws -> [ChatMessage]
	func appendChatMessage(_ message: ChatMessage) async throws
	func enqueue(_ job: AIJob) async throws
	func claimNextJob(now: Date) async throws -> AIJob?
	func completeJob(id: String) async throws
	func failJob(id: String, error: String, retryAt: Date?) async throws
}

/// SQLite-backed store for translations, rewrites, chat messages and jobs.
///
/// All access goes through a `DatabaseQueue`, which serializes work on a
/// private dispatch queue. The database file path is supplied by the caller so
/// the store has no opinion about where the app keeps its data.
public final class SQLiteAIStore: AIStore, Sendable {

	private let queue: DatabaseQueue

	public init(databasePath: String) {
		self.queue = DatabaseQueue(databasePath: databasePath)
		queue.runCreateStatements(Self.tableCreationStatements)
		queue.runInDatabaseSync { database in
			Self.migrate(database)
		}
	}

	// MARK: - Translation

	public func translation(for articleID: String) async throws -> Translation? {
		try await read { database in
			let sql = "select * from translations where articleID = ? limit 1;"
			guard let resultSet = database.executeQuery(sql, withArgumentsIn: [articleID]) else {
				return nil
			}
			defer {
				resultSet.close()
			}
			guard resultSet.next() else {
				return nil
			}
			return try Self.translation(from: resultSet)
		}
	}

	public func saveTranslation(_ translation: Translation) async throws {
		let blocksData = try JSONEncoder().encode(translation.blocks)
		let blocksJSON = String(decoding: blocksData, as: UTF8.self)
		try await write { database in
			let sql = """
			insert or replace into translations (articleID, titleZh, summaryZh, blocks, model, provider, contentHash, createdAt, updatedAt)
			values (?, ?, ?, ?, ?, ?, ?, ?, ?);
			"""
			let arguments: [Any] = [
				translation.articleID,
				translation.titleZh ?? NSNull(),
				translation.summaryZh ?? NSNull(),
				blocksJSON,
				translation.model,
				translation.provider,
				translation.contentHash,
				translation.createdAt.timeIntervalSince1970,
				translation.updatedAt.timeIntervalSince1970
			]
			guard database.executeUpdate(sql, withArgumentsIn: arguments) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}
		}
	}

	/// Saves only the translated title. Existing blocks, summary and createdAt
	/// are preserved; a missing row is inserted with an empty block list.
	public func saveTitleTranslation(articleID: String, titleZh: String, model: String, contentHash: String, at date: Date) async throws {
		try await write { database in
			let sql = """
			insert into translations (articleID, titleZh, summaryZh, blocks, model, provider, contentHash, createdAt, updatedAt)
			values (?, ?, null, '[]', ?, 'magpie', ?, ?, ?)
			on conflict(articleID) do update set
				titleZh = excluded.titleZh,
				model = excluded.model,
				contentHash = excluded.contentHash,
				updatedAt = excluded.updatedAt;
			"""
			let timestamp = date.timeIntervalSince1970
			let arguments: [Any] = [articleID, titleZh, model, contentHash, timestamp, timestamp]
			guard database.executeUpdate(sql, withArgumentsIn: arguments) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}
		}
	}

	// MARK: - Rewrite

	public func rewrite(for articleID: String) async throws -> Rewrite? {
		try await read { database in
			let sql = "select * from rewrites where articleID = ? limit 1;"
			guard let resultSet = database.executeQuery(sql, withArgumentsIn: [articleID]) else {
				return nil
			}
			defer {
				resultSet.close()
			}
			guard resultSet.next() else {
				return nil
			}
			return Self.rewrite(from: resultSet)
		}
	}

	public func saveRewrite(_ rewrite: Rewrite) async throws {
		try await write { database in
			let sql = """
			insert or replace into rewrites (articleID, title, bodyMarkdown, bodyHTML, model, contentHash, createdAt, updatedAt)
			values (?, ?, ?, ?, ?, ?, ?, ?);
			"""
			let arguments: [Any] = [
				rewrite.articleID,
				rewrite.title,
				rewrite.bodyMarkdown,
				rewrite.bodyHTML ?? NSNull(),
				rewrite.model,
				rewrite.contentHash,
				rewrite.createdAt.timeIntervalSince1970,
				rewrite.updatedAt.timeIntervalSince1970
			]
			guard database.executeUpdate(sql, withArgumentsIn: arguments) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}
		}
	}

	// MARK: - Chat

	public func chatMessages(for articleID: String) async throws -> [ChatMessage] {
		try await read { database in
			let sql = "select * from chat_messages where articleID = ? order by createdAt asc, rowid asc;"
			guard let resultSet = database.executeQuery(sql, withArgumentsIn: [articleID]) else {
				return []
			}
			defer {
				resultSet.close()
			}
			var messages: [ChatMessage] = []
			while resultSet.next() {
				guard let message = Self.chatMessage(from: resultSet) else {
					continue
				}
				messages.append(message)
			}
			return messages
		}
	}

	public func appendChatMessage(_ message: ChatMessage) async throws {
		try await write { database in
			let sql = """
			insert or replace into chat_messages (id, articleID, role, content, model, createdAt)
			values (?, ?, ?, ?, ?, ?);
			"""
			let arguments: [Any] = [
				message.id,
				message.articleID,
				message.role.rawValue,
				message.content,
				message.model ?? NSNull(),
				message.createdAt.timeIntervalSince1970
			]
			guard database.executeUpdate(sql, withArgumentsIn: arguments) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}
		}
	}

	// MARK: - Jobs

	public func enqueue(_ job: AIJob) async throws {
		try await write { database in
			let sql = """
			insert or replace into ai_jobs (id, articleID, kind, priority, status, attempts, availableAt, leaseUntil, lastError, createdAt)
			values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
			"""
			let arguments: [Any] = [
				job.id,
				job.articleID,
				job.kind.rawValue,
				job.priority,
				job.status.rawValue,
				job.attempts,
				job.availableAt.timeIntervalSince1970,
				job.leaseUntil.map { $0.timeIntervalSince1970 } ?? NSNull(),
				job.lastError ?? NSNull(),
				job.createdAt.timeIntervalSince1970
			]
			guard database.executeUpdate(sql, withArgumentsIn: arguments) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}
		}
	}

	public func claimNextJob(now: Date) async throws -> AIJob? {
		try await writeInTransaction { database in
			let selectSQL = """
			select * from ai_jobs
			where (status in ('pending', 'retry') and availableAt <= ?)
			   or (status = 'running' and leaseUntil is not null and leaseUntil <= ?)
			order by priority desc, availableAt asc, createdAt asc
			limit 1;
			"""
			guard let resultSet = database.executeQuery(selectSQL, withArgumentsIn: [now.timeIntervalSince1970, now.timeIntervalSince1970]) else {
				return nil
			}
			defer {
				resultSet.close()
			}
			guard resultSet.next(), let job = Self.job(from: resultSet) else {
				return nil
			}

			let leaseUntil = now.addingTimeInterval(AIQueuePolicy.leaseDuration)
			let updateSQL = "update ai_jobs set status = 'running', attempts = attempts + 1, leaseUntil = ? where id = ?;"
			guard database.executeUpdate(updateSQL, withArgumentsIn: [leaseUntil.timeIntervalSince1970, job.id]) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}

			var claimed = job
			claimed.status = .running
			claimed.attempts += 1
			claimed.leaseUntil = leaseUntil
			return claimed
		}
	}

	public func completeJob(id: String) async throws {
		try await write { database in
			let sql = "update ai_jobs set status = 'completed', leaseUntil = null, lastError = null where id = ?;"
			guard database.executeUpdate(sql, withArgumentsIn: [id]) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}
		}
	}

	public func failJob(id: String, error: String, retryAt: Date?) async throws {
		try await write { database in
			let attemptsSQL = "select attempts from ai_jobs where id = ? limit 1;"
			guard let resultSet = database.executeQuery(attemptsSQL, withArgumentsIn: [id]) else {
				return
			}
			let attempts: Int
			if resultSet.next() {
				attempts = Int(resultSet.int(forColumn: "attempts"))
			} else {
				attempts = 0
			}
			resultSet.close()

			let nextRetryAt = retryAt ?? AIQueuePolicy.retryDelay(afterAttempt: attempts).map { Date().addingTimeInterval($0) }
			let sql: String
			let arguments: [Any]
			if let nextRetryAt {
				sql = "update ai_jobs set status = 'retry', availableAt = ?, leaseUntil = null, lastError = ? where id = ?;"
				arguments = [nextRetryAt.timeIntervalSince1970, error, id]
			} else {
				sql = "update ai_jobs set status = 'failed', leaseUntil = null, lastError = ? where id = ?;"
				arguments = [error, id]
			}
			guard database.executeUpdate(sql, withArgumentsIn: arguments) else {
				throw AIStoreError.writeFailed(database.lastErrorMessage())
			}
		}
	}
}

// MARK: - Schema

private extension SQLiteAIStore {

	static let tableCreationStatements = """
	CREATE TABLE if not EXISTS translations (articleID TEXT NOT NULL PRIMARY KEY, titleZh TEXT, summaryZh TEXT, blocks TEXT NOT NULL, model TEXT NOT NULL, provider TEXT NOT NULL, contentHash TEXT NOT NULL, createdAt REAL NOT NULL, updatedAt REAL NOT NULL);

	CREATE TABLE if not EXISTS rewrites (articleID TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, bodyMarkdown TEXT NOT NULL, bodyHTML TEXT, model TEXT NOT NULL, contentHash TEXT NOT NULL, createdAt REAL NOT NULL, updatedAt REAL NOT NULL);

	CREATE TABLE if not EXISTS chat_messages (id TEXT NOT NULL PRIMARY KEY, articleID TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, model TEXT, createdAt REAL NOT NULL);

	CREATE TABLE if not EXISTS ai_jobs (id TEXT NOT NULL PRIMARY KEY, articleID TEXT NOT NULL, kind TEXT NOT NULL, priority INTEGER NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL, availableAt REAL NOT NULL, leaseUntil REAL, lastError TEXT, createdAt REAL NOT NULL);

	CREATE INDEX if not EXISTS chat_messages_articleID_createdAt on chat_messages (articleID, createdAt);

	CREATE INDEX if not EXISTS ai_jobs_status_availableAt on ai_jobs (status, availableAt);
	"""

	static let migrations: [(table: String, column: String, definition: String)] = [
		("translations", "titleZh", "TEXT"),
		("translations", "summaryZh", "TEXT"),
		("rewrites", "bodyHTML", "TEXT"),
		("chat_messages", "model", "TEXT"),
		("ai_jobs", "leaseUntil", "REAL"),
		("ai_jobs", "lastError", "TEXT")
	]

	static func migrate(_ database: FMDatabase) {
		for migration in migrations where !columnExists(migration.column, in: migration.table, database: database) {
			database.executeStatements("ALTER TABLE \(migration.table) add column \(migration.column) \(migration.definition);")
		}
	}

	static func columnExists(_ column: String, in table: String, database: FMDatabase) -> Bool {
		guard let resultSet = database.executeQuery("pragma table_info(\(table));", withArgumentsIn: nil) else {
			return false
		}
		defer {
			resultSet.close()
		}
		while resultSet.next() {
			if resultSet.swiftString(forColumn: "name")?.lowercased() == column.lowercased() {
				return true
			}
		}
		return false
	}
}

// MARK: - Row mapping

private extension SQLiteAIStore {

	static func translation(from resultSet: FMResultSet) throws -> Translation {
		let blocksJSON = resultSet.swiftString(forColumn: "blocks") ?? "[]"
		let blocks: [TranslationBlock]
		do {
			blocks = try JSONDecoder().decode([TranslationBlock].self, from: Data(blocksJSON.utf8))
		} catch {
			throw AIStoreError.corruptRow("Unable to decode translation blocks: \(error)")
		}
		return Translation(
			articleID: resultSet.swiftString(forColumn: "articleID") ?? "",
			titleZh: resultSet.swiftString(forColumn: "titleZh"),
			summaryZh: resultSet.swiftString(forColumn: "summaryZh"),
			blocks: blocks,
			model: resultSet.swiftString(forColumn: "model") ?? "",
			provider: resultSet.swiftString(forColumn: "provider") ?? "",
			contentHash: resultSet.swiftString(forColumn: "contentHash") ?? "",
			createdAt: Date(timeIntervalSince1970: resultSet.double(forColumn: "createdAt")),
			updatedAt: Date(timeIntervalSince1970: resultSet.double(forColumn: "updatedAt"))
		)
	}

	static func rewrite(from resultSet: FMResultSet) -> Rewrite {
		Rewrite(
			articleID: resultSet.swiftString(forColumn: "articleID") ?? "",
			title: resultSet.swiftString(forColumn: "title") ?? "",
			bodyMarkdown: resultSet.swiftString(forColumn: "bodyMarkdown") ?? "",
			bodyHTML: resultSet.swiftString(forColumn: "bodyHTML"),
			model: resultSet.swiftString(forColumn: "model") ?? "",
			contentHash: resultSet.swiftString(forColumn: "contentHash") ?? "",
			createdAt: Date(timeIntervalSince1970: resultSet.double(forColumn: "createdAt")),
			updatedAt: Date(timeIntervalSince1970: resultSet.double(forColumn: "updatedAt"))
		)
	}

	static func chatMessage(from resultSet: FMResultSet) -> ChatMessage? {
		guard let role = resultSet.swiftString(forColumn: "role").flatMap(ChatRole.init(rawValue:)) else {
			return nil
		}
		return ChatMessage(
			id: resultSet.swiftString(forColumn: "id") ?? "",
			articleID: resultSet.swiftString(forColumn: "articleID") ?? "",
			role: role,
			content: resultSet.swiftString(forColumn: "content") ?? "",
			model: resultSet.swiftString(forColumn: "model"),
			createdAt: Date(timeIntervalSince1970: resultSet.double(forColumn: "createdAt"))
		)
	}

	static func job(from resultSet: FMResultSet) -> AIJob? {
		guard
			let kind = resultSet.swiftString(forColumn: "kind").flatMap(AIJobKind.init(rawValue:)),
			let status = resultSet.swiftString(forColumn: "status").flatMap(AIJobStatus.init(rawValue:))
		else {
			return nil
		}
		let leaseUntil: Date?
		if resultSet.object(forColumnName: "leaseUntil") != nil {
			leaseUntil = Date(timeIntervalSince1970: resultSet.double(forColumn: "leaseUntil"))
		} else {
			leaseUntil = nil
		}
		return AIJob(
			id: resultSet.swiftString(forColumn: "id") ?? "",
			articleID: resultSet.swiftString(forColumn: "articleID") ?? "",
			kind: kind,
			priority: Int(resultSet.int(forColumn: "priority")),
			status: status,
			attempts: Int(resultSet.int(forColumn: "attempts")),
			availableAt: Date(timeIntervalSince1970: resultSet.double(forColumn: "availableAt")),
			leaseUntil: leaseUntil,
			lastError: resultSet.swiftString(forColumn: "lastError"),
			createdAt: Date(timeIntervalSince1970: resultSet.double(forColumn: "createdAt"))
		)
	}
}

// MARK: - Async database access

private extension SQLiteAIStore {

	func read<T: Sendable>(_ block: @escaping @Sendable (FMDatabase) throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			queue.runInDatabase { database in
				do {
					continuation.resume(returning: try block(database))
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	func write(_ block: @escaping @Sendable (FMDatabase) throws -> Void) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			queue.runInDatabase { database in
				do {
					try block(database)
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	/// Runs a read-modify-write sequence inside a single database transaction.
	///
	/// `runInTransaction` commits after the block returns, so the continuation is
	/// resumed from a follow-up block on the same serial queue. Resuming inside
	/// the transaction block would let callers observe the result before the
	/// write is durable (and, in tests, before the file can be torn down).
	func writeInTransaction<T: Sendable>(_ block: @escaping @Sendable (FMDatabase) throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			queue.runInTransaction { database in
				let outcome: Result<T, Error>
				do {
					outcome = .success(try block(database))
				} catch {
					outcome = .failure(error)
				}
				self.queue.runInDatabase { _ in
					continuation.resume(with: outcome)
				}
			}
		}
	}
}

public enum AIStoreError: Error, Sendable {
	case writeFailed(String)
	case corruptRow(String)
}
