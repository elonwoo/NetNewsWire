//
//  AIChineseCleanupTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite(.serialized)
final class AIChineseCleanupTests {

	private var store: SQLiteAIStore!
	private let databasePath: String
	private var backupPaths: [String] = []

	init() {
		self.databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIChineseCleanupTests-\(UUID().uuidString).sqlite")
			.path
		self.store = SQLiteAIStore(databasePath: databasePath)
	}

	deinit {
		store = nil
		let fileManager = FileManager.default
		try? fileManager.removeItem(atPath: databasePath)
		try? fileManager.removeItem(atPath: databasePath + "-wal")
		try? fileManager.removeItem(atPath: databasePath + "-shm")
		for path in backupPaths {
			try? fileManager.removeItem(atPath: path)
		}
	}

	@Test func deletesChineseCacheAndUnfinishedJobsOnly() async throws {
		let fixture = try await seedFixture()
		let backupPath = makeBackupPath()

		let result = await AIChineseCleanup.run(store: store, backupPath: backupPath, source: fixture.source)

		#expect(result.succeeded)
		#expect(result.performed)
		#expect(result.chineseArticleCount == 2)
		#expect(result.deletedRewriteCount == 2)
		#expect(result.deletedTranslationCount == 2)
		#expect(result.deletedJobCount == 2)
		#expect(FileManager.default.fileExists(atPath: backupPath))
		#expect(try await store.rewrite(for: fixture.chineseID) == nil)
		#expect(try await store.translation(for: fixture.chineseID) == nil)
		#expect(try await store.rewrite(for: fixture.englishID) != nil)
		#expect(try await store.translation(for: fixture.englishID) != nil)

		let inventory = try await store.inventory()
		#expect(inventory.activeJobArticleIDs == [fixture.englishID])
		#expect(inventory.completedJobArticleIDs == [fixture.chineseID, fixture.chineseTwoID, fixture.englishID])
		#expect(inventory.failedJobArticleIDs == [fixture.chineseID, fixture.chineseTwoID, fixture.englishID])
		#expect(inventory.chatMessageCount == 3)
	}

	@Test func englishCacheAndJobHistoryAreUnchanged() async throws {
		let fixture = try await seedFixture()
		let before = try await store.inventory()
		let backupPath = makeBackupPath()

		_ = await AIChineseCleanup.run(store: store, backupPath: backupPath, source: fixture.source)

		let after = try await store.inventory()
		#expect(after.rewriteArticleIDs.subtracting(fixture.chineseIDs) == before.rewriteArticleIDs.subtracting(fixture.chineseIDs))
		#expect(after.translationArticleIDs.subtracting(fixture.chineseIDs) == before.translationArticleIDs.subtracting(fixture.chineseIDs))
		#expect(after.completedJobArticleIDs == before.completedJobArticleIDs)
		#expect(after.failedJobArticleIDs == before.failedJobArticleIDs)
		#expect(after.chatMessageCount == before.chatMessageCount)
	}

	@Test func selfCheckFailureLeavesTheDatabaseUntouched() async throws {
		let fixture = try await seedFixture()
		let before = try await store.inventory()
		let backupPath = makeBackupPath()

		let result = await AIChineseCleanup.run(
			store: store,
			backupPath: backupPath,
			source: fixture.source,
			backupVerifier: { _, _ in false }
		)

		#expect(!result.succeeded)
		#expect(!result.performed)
		#expect(result.deletedRewriteCount == 0)
		#expect(result.deletedTranslationCount == 0)
		#expect(result.deletedJobCount == 0)
		#expect(try await store.inventory() == before)
	}

	@Test func emptySourceIsASuccessfulNoOp() async throws {
		let backupPath = makeBackupPath()

		let result = await AIChineseCleanup.run(
			store: store,
			backupPath: backupPath,
			source: AIChineseCleanupSource(accounts: [])
		)

		#expect(result.succeeded)
		#expect(!result.performed)
		#expect(!FileManager.default.fileExists(atPath: backupPath))
	}
}

// MARK: - Fixture

private extension AIChineseCleanupTests {

	struct Fixture {
		let source: AIChineseCleanupSource
		let chineseID: String
		let chineseTwoID: String
		let englishID: String

		var chineseIDs: Set<String> {
			[chineseID, chineseTwoID]
		}
	}

	func seedFixture() async throws -> Fixture {
		let chineseID = "zh-article"
		let englishID = "en-article"
		// Two Chinese articles so the delete counts are unambiguous.
		let chineseTwoID = "zh-article-two"
		let now = Date()
		for (index, articleID) in [chineseID, chineseTwoID, englishID].enumerated() {
			try await store.saveRewrite(
				AI.Rewrite(
					articleID: articleID,
					title: "Title \(index)",
					bodyMarkdown: "Body",
					model: "test-model",
					contentHash: "hash-\(index)",
					createdAt: now,
					updatedAt: now
				)
			)
			try await store.saveTranslation(
				AI.Translation(
					articleID: articleID,
					titleZh: "标题",
					blocks: [TranslationBlock(index: 0, source: "Hello", target: "你好")],
					model: "test-model",
					provider: "magpie",
					contentHash: "hash-\(index)",
					createdAt: now,
					updatedAt: now
				)
			)
			try await store.appendChatMessage(
				ChatMessage(id: "chat-\(index)", articleID: articleID, role: .user, content: "hi", createdAt: now)
			)
			try await store.enqueue(
				AIJob(id: "completed-\(index)", articleID: articleID, kind: .rewrite, priority: 0, status: .completed, availableAt: now, createdAt: now)
			)
			try await store.enqueue(
				AIJob(id: "failed-\(index)", articleID: articleID, kind: .rewrite, priority: 0, status: .failed, availableAt: now, createdAt: now)
			)
		}
		// Chinese unfinished jobs are removed; the English one stays.
		try await store.enqueue(
			AIJob(id: "retry-zh", articleID: chineseID, kind: .rewrite, priority: 0, status: .retry, availableAt: now, createdAt: now)
		)
		try await store.enqueue(
			AIJob(id: "retry-zh-two", articleID: chineseTwoID, kind: .bodyTranslation, priority: 0, status: .running, availableAt: now, leaseUntil: now.addingTimeInterval(300), createdAt: now)
		)
		try await store.enqueue(
			AIJob(id: "pending-en", articleID: englishID, kind: .titleTranslation, priority: 0, status: .pending, availableAt: now, createdAt: now)
		)

		let chineseArticle = AIArticle(
			id: chineseID,
			title: "中文标题",
			contentText: String(repeating: "中", count: 2500),
			feedID: "zh-feed",
			publishedAt: now
		)
		let chineseTwoArticle = AIArticle(
			id: chineseTwoID,
			title: "另一个中文标题",
			contentText: String(repeating: "文", count: 2500),
			feedID: "zh-feed",
			publishedAt: now
		)
		let englishArticle = AIArticle(
			id: englishID,
			title: "English title",
			contentText: String(repeating: "a", count: 2500),
			feedID: "en-feed",
			publishedAt: now
		)
		let source = AIChineseCleanupSource(accounts: [
			AIChineseCleanupSource.AccountArticles(
				accountID: "account-1",
				articles: [chineseArticle, chineseTwoArticle, englishArticle]
			)
		])
		return Fixture(source: source, chineseID: chineseID, chineseTwoID: chineseTwoID, englishID: englishID)
	}

	func makeBackupPath() -> String {
		let path = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIChineseCleanupTests-backup-\(UUID().uuidString).db")
			.path
		backupPaths.append(path)
		return path
	}
}
