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

	@Test func activeJobArticleIDsReturnsOnlyUnfinishedJobsOfGivenKinds() async throws {
		let date = Date(timeIntervalSince1970: 1_700_000_350)
		try await store.enqueue(AIJob(id: "job-pending", articleID: "article-pending", kind: .rewrite, priority: 5, status: .pending, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "job-running", articleID: "article-running", kind: .rewrite, priority: 5, status: .running, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "job-retry", articleID: "article-retry", kind: .rewrite, priority: 5, status: .retry, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "job-completed", articleID: "article-completed", kind: .rewrite, priority: 5, status: .completed, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "job-failed", articleID: "article-failed", kind: .rewrite, priority: 5, status: .failed, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "job-title", articleID: "article-title", kind: .titleTranslation, priority: 5, status: .pending, availableAt: date, createdAt: date))

		let rewriteIDs = try await store.activeJobArticleIDs(kinds: [.rewrite])
		#expect(rewriteIDs == ["article-pending", "article-running", "article-retry"])

		let bothIDs = try await store.activeJobArticleIDs(kinds: [.rewrite, .titleTranslation])
		#expect(bothIDs == ["article-pending", "article-running", "article-retry", "article-title"])

		let bodyIDs = try await store.activeJobArticleIDs(kinds: [.bodyTranslation])
		#expect(bodyIDs.isEmpty)
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

	@Test func deleteAIArtifactsRemovesRowsForGivenArticlesOnly() async throws {
		let date = Date(timeIntervalSince1970: 1_700_000_700)
		try await store.saveTranslation(Translation(articleID: "removed", titleZh: "标题", blocks: [], model: "m", provider: "p", contentHash: "h", createdAt: date, updatedAt: date))
		try await store.saveRewrite(Rewrite(articleID: "removed", title: "标题", bodyMarkdown: "正文", model: "m", contentHash: "h", createdAt: date, updatedAt: date))
		try await store.saveTranslation(Translation(articleID: "kept", titleZh: "标题", blocks: [], model: "m", provider: "p", contentHash: "h", createdAt: date, updatedAt: date))
		try await store.saveRewrite(Rewrite(articleID: "kept", title: "标题", bodyMarkdown: "正文", model: "m", contentHash: "h", createdAt: date, updatedAt: date))
		try await store.enqueue(AIJob(id: "job-removed", articleID: "removed", kind: .rewrite, priority: 10, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "job-kept", articleID: "kept", kind: .rewrite, priority: 5, availableAt: date, createdAt: date))

		try await store.deleteAIArtifacts(articleIDs: ["removed"])

		#expect(try await store.translation(for: "removed") == nil)
		#expect(try await store.rewrite(for: "removed") == nil)
		#expect(try await store.translation(for: "kept") != nil)
		#expect(try await store.rewrite(for: "kept") != nil)
		let claimed = try #require(try await store.claimNextJob(now: date))
		#expect(claimed.articleID == "kept")
	}

	@Test func failJobPermanentlyStopsRetries() async throws {
		let date = Date(timeIntervalSince1970: 1_700_000_800)
		try await store.enqueue(AIJob(id: "job-terminal", articleID: "article-9", kind: .bodyTranslation, priority: 100, availableAt: date, createdAt: date))
		_ = try #require(try await store.claimNextJob(now: date))

		try await store.failJobPermanently(id: "job-terminal", error: "找不到文章")

		#expect(try await store.claimNextJob(now: date.addingTimeInterval(24 * 60 * 60)) == nil)
	}

	@Test func completedRewriteArticleIDsIsEmptyForEmptyInput() async throws {
		let completed = try await store.completedRewriteArticleIDs(for: [])
		#expect(completed.isEmpty)
	}

	@Test func completedRewriteArticleIDsReturnsOnlyArticlesWithRewrites() async throws {
		let date = Date(timeIntervalSince1970: 1_700_000_900)
		try await store.saveRewrite(Rewrite(articleID: "has-rewrite", title: "标题", bodyMarkdown: "正文", model: "m", contentHash: "h", createdAt: date, updatedAt: date))
		try await store.saveTranslation(Translation(articleID: "translation-only", titleZh: "标题", blocks: [], model: "m", provider: "p", contentHash: "h", createdAt: date, updatedAt: date))

		let completed = try await store.completedRewriteArticleIDs(for: ["has-rewrite", "translation-only", "missing"])
		#expect(completed == ["has-rewrite"])
	}

	@Test func completedRewriteArticleIDsQueriesAcrossBatchesAndSubsets() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_000)
		let rewrittenIDs = Set((0..<501).map { "batch-\($0)" })
		for articleID in rewrittenIDs {
			try await store.saveRewrite(Rewrite(articleID: articleID, title: "标题", bodyMarkdown: "正文", model: "m", contentHash: "h", createdAt: date, updatedAt: date))
		}
		let missingIDs = Set((501..<521).map { "batch-\($0)" })

		let completed = try await store.completedRewriteArticleIDs(for: rewrittenIDs.union(missingIDs))
		#expect(completed == rewrittenIDs)
	}

	@Test func completedTranslationArticleIDsIsEmptyForEmptyInput() async throws {
		let completed = try await store.completedTranslationArticleIDs(for: [])
		#expect(completed.isEmpty)
	}

	@Test func completedTranslationArticleIDsExcludesTitleOnlyTranslation() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_100)
		try await store.saveTitleTranslation(articleID: "title-only", titleZh: "标题", model: "m", contentHash: "h", at: date)

		let completed = try await store.completedTranslationArticleIDs(for: ["title-only", "missing"])
		#expect(completed.isEmpty)
	}

	@Test func completedTranslationArticleIDsCountsBodyTranslation() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_200)
		let translation = Translation(
			articleID: "body-translated",
			titleZh: nil,
			blocks: [TranslationBlock(index: 0, source: "Hello", target: "你好")],
			model: "m",
			provider: "p",
			contentHash: "h",
			createdAt: date,
			updatedAt: date
		)
		try await store.saveTranslation(translation)

		let completed = try await store.completedTranslationArticleIDs(for: ["body-translated", "missing"])
		#expect(completed == ["body-translated"])
	}

	@Test func completedTranslationArticleIDsReturnsOnlyBodyTranslatedSubset() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_250)
		try await store.saveTitleTranslation(articleID: "title-only", titleZh: "标题", model: "m", contentHash: "h", at: date)
		try await store.saveTranslation(Translation(articleID: "body-translated", titleZh: "标题", blocks: [TranslationBlock(index: 0, source: "Hello", target: "你好")], model: "m", provider: "p", contentHash: "h", createdAt: date, updatedAt: date))

		let completed = try await store.completedTranslationArticleIDs(for: ["title-only", "body-translated", "missing"])
		#expect(completed == ["body-translated"])
	}

	@Test func completedTranslationArticleIDsIgnoresRewriteOnlyRows() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_300)
		try await store.saveRewrite(Rewrite(articleID: "rewrite-only", title: "标题", bodyMarkdown: "正文", model: "m", contentHash: "h", createdAt: date, updatedAt: date))

		let completed = try await store.completedTranslationArticleIDs(for: ["rewrite-only"])
		#expect(completed.isEmpty)
	}

	@Test func completedTranslationArticleIDsQueriesAcrossBatchesAndSubsets() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_400)
		let translatedIDs = Set((0..<501).map { "batch-t-\($0)" })
		for articleID in translatedIDs {
			try await store.saveTranslation(Translation(articleID: articleID, titleZh: "标题", blocks: [TranslationBlock(index: 0, source: "Hello", target: "你好")], model: "m", provider: "p", contentHash: "h", createdAt: date, updatedAt: date))
		}
		let missingIDs = Set((501..<521).map { "batch-t-\($0)" })

		let completed = try await store.completedTranslationArticleIDs(for: translatedIDs.union(missingIDs))
		#expect(completed == translatedIDs)
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
