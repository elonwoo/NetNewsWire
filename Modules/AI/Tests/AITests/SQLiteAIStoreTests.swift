//
//  SQLiteAIStoreTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class SQLiteAIStoreTests {

	private let store: SQLiteAIStore
	private let databasePath: String

	init() {
		self.databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIStoreTests-\(UUID().uuidString).sqlite")
			.path
		self.store = SQLiteAIStore(databasePath: databasePath)
	}

	deinit {
		Self.removeDatabase(at: databasePath)
	}

	@Test func translationRoundTrips() async throws {
		let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
		let updatedAt = createdAt.addingTimeInterval(60)
		let translation = Translation(
			articleID: "article-1",
			titleZh: "中文标题",
			summaryZh: "中文摘要",
			blocks: [
				TranslationBlock(index: 0, source: "Hello", target: "你好", targetHTML: "<p>你好</p>"),
				TranslationBlock(index: 1, source: "World", target: "世界", targetHTML: nil)
			],
			model: "test-model",
			provider: "openai",
			contentHash: "abc123",
			createdAt: createdAt,
			updatedAt: updatedAt
		)

		try await store.saveTranslation(translation)
		let loaded = try await store.translation(for: "article-1")

		#expect(loaded == translation)
		#expect(try await store.translation(for: "missing") == nil)
	}

	@Test func rewriteRoundTrips() async throws {
		let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
		let rewrite = Rewrite(
			articleID: "article-2",
			title: "标题",
			bodyMarkdown: "# 正文\n\n内容",
			bodyHTML: "<h1>正文</h1>",
			model: "test-model",
			contentHash: "def456",
			createdAt: createdAt,
			updatedAt: createdAt
		)

		try await store.saveRewrite(rewrite)
		let loaded = try await store.rewrite(for: "article-2")

		#expect(loaded == rewrite)
		#expect(try await store.rewrite(for: "missing") == nil)
	}

	@Test func chatMessagesRoundTripInOrder() async throws {
		let base = Date(timeIntervalSince1970: 1_700_000_200)
		let first = ChatMessage(id: "m1", articleID: "article-3", role: .user, content: "问题", model: nil, createdAt: base)
		let second = ChatMessage(id: "m2", articleID: "article-3", role: .assistant, content: "回答", model: "test-model", createdAt: base.addingTimeInterval(1))
		let other = ChatMessage(id: "m3", articleID: "article-4", role: .user, content: "别处", model: nil, createdAt: base)

		try await store.appendChatMessage(first)
		try await store.appendChatMessage(second)
		try await store.appendChatMessage(other)

		let messages = try await store.chatMessages(for: "article-3")
		#expect(messages == [first, second])
	}

	@Test func jobRoundTrips() async throws {
		let createdAt = Date(timeIntervalSince1970: 1_700_000_300)
		let job = AIJob(id: "job-1", articleID: "article-5", kind: .bodyTranslation, priority: 5, availableAt: createdAt, createdAt: createdAt)

		try await store.enqueue(job)
		let claimed = try await store.claimNextJob(now: createdAt)

		let loaded = try #require(claimed)
		#expect(loaded.id == "job-1")
		#expect(loaded.articleID == "article-5")
		#expect(loaded.kind == .bodyTranslation)
		#expect(loaded.priority == 5)
		#expect(loaded.status == .running)
		#expect(loaded.attempts == 1)
		#expect(loaded.leaseUntil == createdAt.addingTimeInterval(AIQueuePolicy.leaseDuration))
	}

	@Test func savingTranslationReplacesExistingRow() async throws {
		let createdAt = Date(timeIntervalSince1970: 1_700_000_400)
		let first = Translation(articleID: "article-6", titleZh: "旧", blocks: [], model: "m", provider: "p", contentHash: "h1", createdAt: createdAt, updatedAt: createdAt)
		let second = Translation(articleID: "article-6", titleZh: "新", blocks: [], model: "m", provider: "p", contentHash: "h2", createdAt: createdAt, updatedAt: createdAt)

		try await store.saveTranslation(first)
		try await store.saveTranslation(second)

		let loaded = try #require(try await store.translation(for: "article-6"))
		#expect(loaded.titleZh == "新")
		#expect(loaded.contentHash == "h2")
	}

	@Test func saveTitleTranslationInsertsRowWithEmptyBlocks() async throws {
		let date = Date(timeIntervalSince1970: 1_700_000_500)
		try await store.saveTitleTranslation(articleID: "article-7", titleZh: "中文标题", model: "test-model", contentHash: "hash-7", at: date)

		let loaded = try #require(try await store.translation(for: "article-7"))
		#expect(loaded.titleZh == "中文标题")
		#expect(loaded.blocks.isEmpty)
		#expect(loaded.model == "test-model")
		#expect(loaded.provider == "magpie")
		#expect(loaded.contentHash == "hash-7")
		#expect(loaded.createdAt == date)
		#expect(loaded.updatedAt == date)
	}

	@Test func saveTitleTranslationPreservesExistingBlocks() async throws {
		let createdAt = Date(timeIntervalSince1970: 1_700_000_600)
		let block = TranslationBlock(index: 0, source: "Hello", target: "你好", targetHTML: "<p>你好</p>")
		let existing = Translation(
			articleID: "article-8",
			titleZh: "旧标题",
			summaryZh: "摘要",
			blocks: [block],
			model: "old-model",
			provider: "magpie",
			contentHash: "old-hash",
			createdAt: createdAt,
			updatedAt: createdAt
		)
		try await store.saveTranslation(existing)

		let updatedAt = createdAt.addingTimeInterval(120)
		try await store.saveTitleTranslation(articleID: "article-8", titleZh: "新标题", model: "new-model", contentHash: "new-hash", at: updatedAt)

		let loaded = try #require(try await store.translation(for: "article-8"))
		#expect(loaded.titleZh == "新标题")
		#expect(loaded.blocks == [block])
		#expect(loaded.summaryZh == "摘要")
		#expect(loaded.model == "new-model")
		#expect(loaded.contentHash == "new-hash")
		#expect(loaded.createdAt == createdAt)
		#expect(loaded.updatedAt == updatedAt)
	}
}

private extension SQLiteAIStoreTests {

	static func removeDatabase(at path: String) {
		let fileManager = FileManager.default
		try? fileManager.removeItem(atPath: path)
		try? fileManager.removeItem(atPath: path + "-wal")
		try? fileManager.removeItem(atPath: path + "-shm")
	}
}
