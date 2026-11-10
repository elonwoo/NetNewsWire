//
//  SQLiteAIStoreTests.swift
//  AITests
//

import Foundation
import SQLite3
import Testing
@testable import AI

@Suite final class SQLiteAIStoreTests {

	private let store: SQLiteAIStore
	private let databasePath: String
	private let notificationCenter: NotificationCenter

	init() {
		self.databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIStoreTests-\(UUID().uuidString).sqlite")
			.path
		let notificationCenter = NotificationCenter()
		self.notificationCenter = notificationCenter
		self.store = SQLiteAIStore(databasePath: databasePath, notificationCenter: notificationCenter)
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

	// MARK: - Job kind filtering

	@Test func claimFiltersPendingJobsByKind() async throws {
		let date = Date(timeIntervalSince1970: 1_700_002_000)
		// The rewrite has the higher priority, so an unfiltered (or incorrectly
		// parenthesised) query would hand it to the translation lane first.
		try await store.enqueue(AIJob(id: "rewrite-pending", articleID: "article-rewrite", kind: .rewrite, priority: 10, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "title-pending", articleID: "article-title", kind: .titleTranslation, priority: 0, availableAt: date, createdAt: date))

		let titleJob = try #require(try await store.claimNextJob(now: date, allowedKinds: [.titleTranslation]))
		#expect(titleJob.id == "title-pending")
		#expect(try await store.claimNextJob(now: date, allowedKinds: [.titleTranslation]) == nil)

		let rewriteJob = try #require(try await store.claimNextJob(now: date, allowedKinds: [.rewrite]))
		#expect(rewriteJob.id == "rewrite-pending")
	}

	@Test func claimFiltersRetryJobsByKind() async throws {
		let date = Date(timeIntervalSince1970: 1_700_002_100)
		try await store.enqueue(AIJob(id: "rewrite-retry", articleID: "article-retry", kind: .rewrite, priority: 10, status: .retry, availableAt: date, createdAt: date))

		#expect(try await store.claimNextJob(now: date, allowedKinds: [.bodyTranslation, .titleTranslation]) == nil)

		let reclaimed = try #require(try await store.claimNextJob(now: date, allowedKinds: [.rewrite]))
		#expect(reclaimed.id == "rewrite-retry")
		#expect(reclaimed.status == .running)
	}

	@Test func claimWithEmptyAllowedKindsReturnsNil() async throws {
		let date = Date(timeIntervalSince1970: 1_700_002_200)
		try await store.enqueue(AIJob(id: "job-any-kind", articleID: "article", kind: .rewrite, priority: 1, availableAt: date, createdAt: date))

		#expect(try await store.claimNextJob(now: date, allowedKinds: []) == nil)
	}

	@Test func concurrentClaimsWithDifferentKindsReturnDifferentJobs() async throws {
		let date = Date(timeIntervalSince1970: 1_700_002_300)
		try await store.enqueue(AIJob(id: "rewrite-lane", articleID: "article-rewrite", kind: .rewrite, priority: 0, availableAt: date, createdAt: date))
		try await store.enqueue(AIJob(id: "title-lane", articleID: "article-title", kind: .titleTranslation, priority: 0, availableAt: date, createdAt: date))

		let store = self.store
		async let interactive = store.claimNextJob(now: date, allowedKinds: [.bodyTranslation, .titleTranslation])
		async let background = store.claimNextJob(now: date, allowedKinds: [.rewrite])
		let (interactiveJob, backgroundJob) = try await (interactive, background)

		#expect(interactiveJob?.id == "title-lane")
		#expect(backgroundJob?.id == "rewrite-lane")
	}

	@Test func renewLeaseKeepsRunningJobClaimed() async throws {
		let date = Date(timeIntervalSince1970: 1_700_002_400)
		try await store.enqueue(AIJob(id: "lease-job", articleID: "article-lease", kind: .bodyTranslation, priority: 0, availableAt: date, createdAt: date))
		let claimed = try #require(try await store.claimNextJob(now: date, allowedKinds: [.bodyTranslation]))
		#expect(claimed.leaseUntil == date.addingTimeInterval(AIQueuePolicy.leaseDuration))

		let renewedAt = date.addingTimeInterval(2 * 60)
		try await store.renewLease(id: "lease-job", now: renewedAt)

		// The original expiry no longer ends the lease.
		#expect(try await store.claimNextJob(now: date.addingTimeInterval(AIQueuePolicy.leaseDuration)) == nil)

		let reclaimed = try #require(try await store.claimNextJob(now: renewedAt.addingTimeInterval(AIQueuePolicy.leaseDuration)))
		#expect(reclaimed.id == "lease-job")
		#expect(reclaimed.attempts == 2)
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

	@Test func translatedTitlesIsEmptyForEmptyInput() async throws {
		let titles = try await store.translatedTitles(for: [])
		#expect(titles.isEmpty)
	}

	@Test func translatedTitlesIncludesTitleOnlyRows() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_500)
		try await store.saveTitleTranslation(articleID: "title-only", titleZh: "中文标题", model: "m", contentHash: "h", at: date)
		try await store.saveTranslation(Translation(articleID: "body-translated", titleZh: "正文标题", blocks: [TranslationBlock(index: 0, source: "Hello", target: "你好")], model: "m", provider: "p", contentHash: "h", createdAt: date, updatedAt: date))

		let titles = try await store.translatedTitles(for: ["title-only", "body-translated", "missing"])
		#expect(titles == ["title-only": "中文标题", "body-translated": "正文标题"])
	}

	@Test func translatedTitlesExcludesMissingAndBlankTitles() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_600)
		try await store.saveTitleTranslation(articleID: "empty-title", titleZh: "", model: "m", contentHash: "h", at: date)
		try await store.saveTitleTranslation(articleID: "blank-title", titleZh: "   ", model: "m", contentHash: "h", at: date)
		try await store.saveTranslation(Translation(articleID: "nil-title", titleZh: nil, blocks: [TranslationBlock(index: 0, source: "Hello", target: "你好")], model: "m", provider: "p", contentHash: "h", createdAt: date, updatedAt: date))

		let titles = try await store.translatedTitles(for: ["empty-title", "blank-title", "nil-title"])
		#expect(titles.isEmpty)
	}

	@Test func translatedTitlesQueriesAcrossBatches() async throws {
		let date = Date(timeIntervalSince1970: 1_700_001_700)
		let titledIDs = Set((0..<701).map { "batch-zh-\($0)" })
		for articleID in titledIDs {
			try await store.saveTitleTranslation(articleID: articleID, titleZh: "标题\(articleID)", model: "m", contentHash: "h", at: date)
		}
		let missingIDs = Set((701..<711).map { "batch-zh-\($0)" })

		let titles = try await store.translatedTitles(for: titledIDs.union(missingIDs))
		#expect(Set(titles.keys) == titledIDs)
		#expect(titles["batch-zh-0"] == "标题batch-zh-0")
		#expect(titles["batch-zh-700"] == "标题batch-zh-700")
	}

	// MARK: - Schema migration

	@Test func repeatedInitialisationKeepsTimestampColumns() async throws {
		// The suite's store is the first initialisation; two more must not
		// duplicate columns or fail.
		_ = SQLiteAIStore(databasePath: databasePath, notificationCenter: NotificationCenter())
		let thirdStore = SQLiteAIStore(databasePath: databasePath, notificationCenter: NotificationCenter())

		let columns = try Self.columnNames(inTable: "ai_jobs", at: databasePath)
		#expect(columns.filter { $0 == "startedAt" }.count == 1)
		#expect(columns.filter { $0 == "finishedAt" }.count == 1)
		#expect(try Self.indexNames(at: databasePath).contains("ai_jobs_status_finishedAt"))

		let date = Date(timeIntervalSince1970: 1_700_003_000)
		try await thirdStore.enqueue(AIJob(id: "after-migrations", articleID: "article", kind: .rewrite, priority: 0, availableAt: date, createdAt: date))
		let claimed = try #require(try await thirdStore.claimNextJob(now: date))
		#expect(claimed.startedAt == date)

		try await thirdStore.completeJob(id: claimed.id)
		let completed = try await thirdStore.recentJobs(status: .completed, since: date, limit: 10)
		#expect(completed.first?.id == "after-migrations")
		#expect(completed.first?.finishedAt != nil)
	}

	@Test func initialisationCreatesFoldedFailureIndex() throws {
		let names = try Self.indexNamesFromPragma(table: "ai_jobs", at: databasePath)
		#expect(names.contains("ai_jobs_article_kind_status_finishedAt"))
	}

	@Test func legacyDatabaseGainsTimestampColumns() async throws {
		let legacyPath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIStoreLegacy-\(UUID().uuidString).sqlite")
			.path
		defer {
			Self.removeDatabase(at: legacyPath)
		}
		// The table as it existed before startedAt/finishedAt were added, with a
		// terminal row that has no finishedAt.
		try Self.execute("""
		CREATE TABLE ai_jobs (id TEXT NOT NULL PRIMARY KEY, articleID TEXT NOT NULL, kind TEXT NOT NULL, priority INTEGER NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL, availableAt REAL NOT NULL, leaseUntil REAL, lastError TEXT, createdAt REAL NOT NULL);
		INSERT INTO ai_jobs (id, articleID, kind, priority, status, attempts, availableAt, leaseUntil, lastError, createdAt) VALUES ('legacy-completed', 'legacy-article', 'rewrite', 0, 'completed', 1, 1700003050, NULL, NULL, 1700003050);
		""", at: legacyPath)

		let legacyStore = SQLiteAIStore(databasePath: legacyPath, notificationCenter: NotificationCenter())

		let columns = try Self.columnNames(inTable: "ai_jobs", at: legacyPath)
		#expect(columns.contains("startedAt"))
		#expect(columns.contains("finishedAt"))
		#expect(try Self.indexNames(at: legacyPath).contains("ai_jobs_status_finishedAt"))

		// Old terminal rows get a finishedAt so cleanup can eventually expire them.
		let legacyCreatedAt = Date(timeIntervalSince1970: 1_700_003_050)
		let backfilled = try await legacyStore.recentJobs(status: .completed, since: legacyCreatedAt.addingTimeInterval(-1), limit: 10)
		let legacyCompleted = try #require(backfilled.first { $0.id == "legacy-completed" })
		let legacyFinishedAt = try #require(legacyCompleted.finishedAt)
		#expect(abs(legacyFinishedAt.timeIntervalSince1970 - legacyCreatedAt.timeIntervalSince1970) < 0.001)

		let date = Date(timeIntervalSince1970: 1_700_003_100)
		try await legacyStore.enqueue(AIJob(id: "legacy-job", articleID: "legacy-article", kind: .bodyTranslation, priority: 0, availableAt: date, createdAt: date))
		let claimed = try #require(try await legacyStore.claimNextJob(now: date))
		#expect(claimed.startedAt == date)

		try await legacyStore.completeJob(id: claimed.id)
		let completed = try await legacyStore.recentJobs(status: .completed, since: date.addingTimeInterval(-1), limit: 10)
		#expect(completed.map(\.id) == ["legacy-job"])
		#expect(completed.first?.finishedAt != nil)
	}

	// MARK: - Job timestamps

	@Test func claimRecordsStartedAtAndReclaimResetsIt() async throws {
		let enqueuedAt = Date(timeIntervalSince1970: 1_700_004_000)
		try await store.enqueue(makeJob(id: "claim-stamp", availableAt: enqueuedAt))

		let firstClaimAt = enqueuedAt.addingTimeInterval(60)
		let first = try #require(try await store.claimNextJob(now: firstClaimAt))
		#expect(first.startedAt == firstClaimAt)
		#expect(first.finishedAt == nil)

		let reclaimedAt = firstClaimAt.addingTimeInterval(AIQueuePolicy.leaseDuration)
		let reclaimed = try #require(try await store.claimNextJob(now: reclaimedAt))
		#expect(reclaimed.id == "claim-stamp")
		#expect(reclaimed.startedAt == reclaimedAt)
		#expect(reclaimed.finishedAt == nil)
	}

	@Test func completeJobRecordsFinishedAt() async throws {
		let enqueuedAt = Date(timeIntervalSince1970: 1_700_004_100)
		try await store.enqueue(makeJob(id: "complete-stamp", availableAt: enqueuedAt))
		let claimed = try #require(try await store.claimNextJob(now: enqueuedAt))
		let before = Date()

		try await store.completeJob(id: claimed.id)

		let completed = try await store.recentJobs(status: .completed, since: enqueuedAt, limit: 10)
		let job = try #require(completed.first)
		#expect(job.id == "complete-stamp")
		#expect(job.startedAt == enqueuedAt)
		let finishedAt = try #require(job.finishedAt)
		// REAL round-tripping can move a stored timestamp by a sub-microsecond
		// amount, so compare with a small tolerance instead of exactly.
		#expect(finishedAt >= before.addingTimeInterval(-0.001))
		#expect(finishedAt <= Date().addingTimeInterval(0.001))
	}

	@Test func terminalFailureRecordsFinishedAt() async throws {
		let enqueuedAt = Date(timeIntervalSince1970: 1_700_004_200)
		try await store.enqueue(makeJob(id: "fail-stamp", status: .retry, attempts: AIQueuePolicy.maxAttempts - 1, availableAt: enqueuedAt))
		let claimed = try #require(try await store.claimNextJob(now: enqueuedAt))
		#expect(claimed.attempts == AIQueuePolicy.maxAttempts)

		try await store.failJob(id: claimed.id, error: "boom", retryAt: nil)

		let failed = try await store.recentJobs(status: .failed, since: enqueuedAt, limit: 10)
		let job = try #require(failed.first)
		#expect(job.id == "fail-stamp")
		#expect(job.startedAt == enqueuedAt)
		let finishedAt = try #require(job.finishedAt)
		#expect(finishedAt >= enqueuedAt.addingTimeInterval(-0.001))
	}

	@Test func permanentFailureRecordsFinishedAt() async throws {
		let enqueuedAt = Date(timeIntervalSince1970: 1_700_004_250)
		try await store.enqueue(makeJob(id: "permanent-fail-stamp", availableAt: enqueuedAt))
		let claimed = try #require(try await store.claimNextJob(now: enqueuedAt))

		try await store.failJobPermanently(id: claimed.id, error: "找不到文章")

		let failed = try await store.recentJobs(status: .failed, since: enqueuedAt, limit: 10)
		#expect(failed.map(\.id) == ["permanent-fail-stamp"])
		#expect(failed.first?.finishedAt != nil)
	}

	@Test func retryClearsStartedAtAndLeavesFinishedAtNil() async throws {
		let enqueuedAt = Date(timeIntervalSince1970: 1_700_004_300)
		try await store.enqueue(makeJob(id: "retry-stamp", availableAt: enqueuedAt))
		let claimed = try #require(try await store.claimNextJob(now: enqueuedAt))
		#expect(claimed.startedAt == enqueuedAt)

		let retryAt = enqueuedAt.addingTimeInterval(10 * 60)
		try await store.failJob(id: claimed.id, error: "boom", retryAt: retryAt)

		let retried = try #require(try await store.activeJobs().first { $0.id == "retry-stamp" })
		#expect(retried.status == .retry)
		#expect(retried.startedAt == nil)
		#expect(retried.finishedAt == nil)

		let reclaimed = try #require(try await store.claimNextJob(now: retryAt))
		#expect(reclaimed.startedAt == retryAt)
	}

	// MARK: - Job queries

	@Test func activeJobsFiltersUnfinishedAndSortsByPriorityAndAvailability() async throws {
		let base = Date(timeIntervalSince1970: 1_700_005_000)
		try await store.enqueue(makeJob(id: "high", priority: 10, status: .pending, availableAt: base.addingTimeInterval(2)))
		try await store.enqueue(makeJob(id: "mid-late", priority: 5, status: .pending, availableAt: base.addingTimeInterval(3)))
		try await store.enqueue(makeJob(id: "mid-early", priority: 5, status: .running, availableAt: base.addingTimeInterval(1)))
		try await store.enqueue(makeJob(id: "low", priority: 0, status: .retry, availableAt: base))
		try await store.enqueue(makeJob(id: "completed", priority: 100, status: .completed, availableAt: base, finishedAt: base))
		try await store.enqueue(makeJob(id: "failed", priority: 100, status: .failed, availableAt: base, finishedAt: base))

		let active = try await store.activeJobs()
		#expect(active.map(\.id) == ["high", "mid-early", "mid-late", "low"])
		#expect(active.allSatisfy { $0.status != .completed && $0.status != .failed })
	}

	@Test func recentJobsFiltersSortsAndLimits() async throws {
		let base = Date(timeIntervalSince1970: 1_700_005_100)
		try await store.enqueue(makeJob(id: "old", status: .completed, availableAt: base, finishedAt: base))
		try await store.enqueue(makeJob(id: "mid", status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "newest", status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(20)))
		try await store.enqueue(makeJob(id: "missing-finished", status: .completed, availableAt: base))
		try await store.enqueue(makeJob(id: "failed", status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(30)))

		let recent = try await store.recentJobs(status: .completed, since: base.addingTimeInterval(10), limit: 10)
		#expect(recent.map(\.id) == ["newest", "mid"])

		let limited = try await store.recentJobs(status: .completed, since: base, limit: 1)
		#expect(limited.map(\.id) == ["newest"])

		let nonTerminal = try await store.recentJobs(status: .running, since: base, limit: 10)
		#expect(nonTerminal.isEmpty)

		let zeroLimit = try await store.recentJobs(status: .completed, since: base, limit: 0)
		#expect(zeroLimit.isEmpty)

		let failed = try await store.recentJobs(status: .failed, since: base, limit: 10)
		#expect(failed.map(\.id) == ["failed"])

		// Equal timestamps fall back to insertion order, newest rowid first, so
		// the panel does not reshuffle identical results between reads.
		let tie = base.addingTimeInterval(50)
		try await store.enqueue(makeJob(id: "tie-first", status: .completed, availableAt: base, finishedAt: tie))
		try await store.enqueue(makeJob(id: "tie-second", status: .completed, availableAt: base, finishedAt: tie))
		let tied = try await store.recentJobs(status: .completed, since: tie, limit: 2)
		#expect(tied.map(\.id) == ["tie-second", "tie-first"])
	}

	@Test func foldedFailuresCollapsesFailuresWithLaterCompletion() async throws {
		let base = Date(timeIntervalSince1970: 1_700_005_200)
		try await store.enqueue(makeJob(id: "visible", articleID: "a1", kind: .rewrite, status: .failed, availableAt: base, lastError: "boom", finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "folds", articleID: "a2", kind: .rewrite, status: .failed, availableAt: base, lastError: "boom", finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "later-completion", articleID: "a2", kind: .rewrite, status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(20)))
		try await store.enqueue(makeJob(id: "earlier-completion", articleID: "a3", kind: .rewrite, status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(5)))
		try await store.enqueue(makeJob(id: "later-failure", articleID: "a3", kind: .rewrite, status: .failed, availableAt: base, lastError: "boom", finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "other-kind-completion", articleID: "a4", kind: .bodyTranslation, status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(20)))
		try await store.enqueue(makeJob(id: "different-kind", articleID: "a4", kind: .rewrite, status: .failed, availableAt: base, lastError: "boom", finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "null-completion", articleID: "a5", kind: .rewrite, status: .completed, availableAt: base))
		try await store.enqueue(makeJob(id: "null-completion-failure", articleID: "a5", kind: .rewrite, status: .failed, availableAt: base, lastError: "boom", finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "null-error", articleID: "a6", kind: .rewrite, status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(15)))

		let folded = try await store.foldedFailures(since: base)
		#expect(Set(folded.map(\.id)) == ["visible", "later-failure", "different-kind", "null-completion-failure", "null-error"])
		#expect(folded.first { $0.id == "null-error" }?.lastError == nil)
	}

	@Test func foldedFailuresSortsByFinishedAtThenRowidDescending() async throws {
		let base = Date(timeIntervalSince1970: 1_700_005_250)
		try await store.enqueue(makeJob(id: "old", status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "tie-first", status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(20)))
		try await store.enqueue(makeJob(id: "tie-second", status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(20)))

		let folded = try await store.foldedFailures(since: base)
		#expect(folded.map(\.id) == ["tie-second", "tie-first", "old"])
	}

	@Test func foldedFailuresFiltersByStatusWindowAndFinishedAt() async throws {
		let base = Date(timeIntervalSince1970: 1_700_005_260)
		try await store.enqueue(makeJob(id: "boundary", articleID: "a1", status: .failed, availableAt: base, finishedAt: base))
		try await store.enqueue(makeJob(id: "older", articleID: "a2", status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(-1)))
		try await store.enqueue(makeJob(id: "no-finish", articleID: "a3", status: .failed, availableAt: base))
		try await store.enqueue(makeJob(id: "not-failed", articleID: "a4", status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "pending", articleID: "a5", status: .pending, availableAt: base))

		let folded = try await store.foldedFailures(since: base)
		#expect(folded.map(\.id) == ["boundary"])
	}

	@Test func deleteTerminalJobsRemovesOnlyExpiredTerminalRows() async throws {
		let base = Date(timeIntervalSince1970: 1_700_005_300)
		let cutoff = base.addingTimeInterval(20)
		try await store.enqueue(makeJob(id: "completed-old", articleID: "article-completed-old", status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(10)))
		try await store.enqueue(makeJob(id: "failed-old", articleID: "article-failed-old", status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(15)))
		try await store.enqueue(makeJob(id: "completed-new", articleID: "article-completed-new", status: .completed, availableAt: base, finishedAt: base.addingTimeInterval(30)))
		try await store.enqueue(makeJob(id: "failed-new", articleID: "article-failed-new", status: .failed, availableAt: base, finishedAt: base.addingTimeInterval(40)))
		try await store.enqueue(makeJob(id: "completed-no-finish", articleID: "article-completed-nil", status: .completed, availableAt: base))
		try await store.enqueue(makeJob(id: "pending-old", articleID: "article-pending", status: .pending, availableAt: base))
		try await store.enqueue(makeJob(id: "running-old", articleID: "article-running", status: .running, availableAt: base))
		try await store.enqueue(makeJob(id: "retry-old", articleID: "article-retry", status: .retry, availableAt: base))

		let deleted = try await store.deleteTerminalJobs(olderThan: cutoff)

		#expect(deleted == 2)
		let inventory = try await store.inventory()
		#expect(inventory.completedJobArticleIDs == ["article-completed-new", "article-completed-nil"])
		#expect(inventory.failedJobArticleIDs == ["article-failed-new"])
		let activeIDs = Set(try await store.activeJobs().map(\.id))
		#expect(activeIDs == ["pending-old", "running-old", "retry-old"])
	}

	// MARK: - Change notifications

	@Test func jobMutationsPostChangeNotificationWithoutPayload() async throws {
		let recorder = JobNotificationRecorder()
		let token = notificationCenter.addObserver(forName: .aiJobsDidChange, object: nil, queue: nil) { notification in
			recorder.record(object: notification.object, userInfo: notification.userInfo)
		}
		defer {
			notificationCenter.removeObserver(token)
		}

		let date = Date(timeIntervalSince1970: 1_700_006_000)
		try await store.enqueue(makeJob(id: "notified", availableAt: date))
		#expect(recorder.count == 1)
		#expect(recorder.allPayloadsEmpty)

		let claimed = try #require(try await store.claimNextJob(now: date))
		#expect(recorder.count == 2)
		#expect(recorder.allPayloadsEmpty)

		try await store.completeJob(id: claimed.id)
		#expect(recorder.count == 3)
		#expect(recorder.allPayloadsEmpty)
	}

	@Test func failedAndRetriedJobsPostChangeNotification() async throws {
		let recorder = JobNotificationRecorder()
		let token = notificationCenter.addObserver(forName: .aiJobsDidChange, object: nil, queue: nil) { notification in
			recorder.record(object: notification.object, userInfo: notification.userInfo)
		}
		defer {
			notificationCenter.removeObserver(token)
		}

		let date = Date(timeIntervalSince1970: 1_700_006_100)
		try await store.enqueue(makeJob(id: "failing", availableAt: date))
		#expect(recorder.count == 1)

		let claimed = try #require(try await store.claimNextJob(now: date))
		#expect(recorder.count == 2)

		let retryAt = date.addingTimeInterval(10 * 60)
		try await store.failJob(id: claimed.id, error: "boom", retryAt: retryAt)
		#expect(recorder.count == 3)
		#expect(recorder.allPayloadsEmpty)

		let reclaimed = try #require(try await store.claimNextJob(now: retryAt))
		#expect(recorder.count == 4)

		try await store.failJob(id: reclaimed.id, error: "boom", retryAt: nil)
		#expect(recorder.count == 5)
		#expect(recorder.allPayloadsEmpty)
	}

	@Test func renewLeaseDoesNotPostChangeNotification() async throws {
		let recorder = JobNotificationRecorder()
		let token = notificationCenter.addObserver(forName: .aiJobsDidChange, object: nil, queue: nil) { notification in
			recorder.record(object: notification.object, userInfo: notification.userInfo)
		}
		defer {
			notificationCenter.removeObserver(token)
		}

		let date = Date(timeIntervalSince1970: 1_700_006_200)
		try await store.enqueue(makeJob(id: "lease", availableAt: date))
		let claimed = try #require(try await store.claimNextJob(now: date))
		recorder.reset()

		try await store.renewLease(id: claimed.id, now: date.addingTimeInterval(60))
		#expect(recorder.count == 0)
	}

	@Test func deletePathsPostChangeNotification() async throws {
		let recorder = JobNotificationRecorder()
		let token = notificationCenter.addObserver(forName: .aiJobsDidChange, object: nil, queue: nil) { notification in
			recorder.record(object: notification.object, userInfo: notification.userInfo)
		}
		defer {
			notificationCenter.removeObserver(token)
		}

		let date = Date(timeIntervalSince1970: 1_700_006_300)

		try await store.enqueue(makeJob(id: "delete-jobs", availableAt: date))
		recorder.reset()
		try await store.deleteJobs(kinds: [.rewrite], statuses: [.pending])
		#expect(recorder.count == 1)

		try await store.enqueue(makeJob(id: "delete-terminal", status: .completed, availableAt: date, finishedAt: date))
		recorder.reset()
		let deleted = try await store.deleteTerminalJobs(olderThan: date.addingTimeInterval(1))
		#expect(deleted == 1)
		#expect(recorder.count == 1)

		try await store.enqueue(makeJob(id: "delete-artifacts", articleID: "artifact-article", availableAt: date))
		recorder.reset()
		try await store.deleteAIArtifacts(articleIDs: ["artifact-article"])
		#expect(recorder.count == 1)

		try await store.enqueue(makeJob(id: "delete-active", articleID: "active-article", availableAt: date))
		recorder.reset()
		let deletion = try await store.deleteActiveAIArtifacts(articleIDs: ["active-article"])
		#expect(deletion.jobCount == 1)
		#expect(recorder.count == 1)
		#expect(recorder.allPayloadsEmpty)
	}

	@Test func noOpWritesDoNotPostChangeNotification() async throws {
		let recorder = JobNotificationRecorder()
		let token = notificationCenter.addObserver(forName: .aiJobsDidChange, object: nil, queue: nil) { notification in
			recorder.record(object: notification.object, userInfo: notification.userInfo)
		}
		defer {
			notificationCenter.removeObserver(token)
		}

		// Updates for a missing row change nothing.
		try await store.completeJob(id: "missing")
		#expect(recorder.count == 0)
		try await store.failJob(id: "missing", error: "boom", retryAt: nil)
		#expect(recorder.count == 0)
		try await store.failJobPermanently(id: "missing", error: "boom")
		#expect(recorder.count == 0)

		// Deletes that match nothing change nothing.
		try await store.deleteJobs(kinds: [.rewrite], statuses: [.failed])
		#expect(recorder.count == 0)
		#expect(try await store.deleteTerminalJobs(olderThan: Date(timeIntervalSince1970: 1_700_006_400)) == 0)
		#expect(recorder.count == 0)
		try await store.deleteAIArtifacts(articleIDs: ["missing"])
		#expect(recorder.count == 0)
		_ = try await store.deleteActiveAIArtifacts(articleIDs: ["missing"])
		#expect(recorder.count == 0)
	}
}

// MARK: - Helpers

private extension SQLiteAIStoreTests {

	func makeJob(
		id: String,
		articleID: String = "article",
		kind: AIJobKind = .rewrite,
		priority: Int = 0,
		status: AIJobStatus = .pending,
		attempts: Int = 0,
		availableAt: Date,
		lastError: String? = nil,
		startedAt: Date? = nil,
		finishedAt: Date? = nil
	) -> AIJob {
		AIJob(
			id: id,
			articleID: articleID,
			kind: kind,
			priority: priority,
			status: status,
			attempts: attempts,
			availableAt: availableAt,
			leaseUntil: nil,
			lastError: lastError,
			startedAt: startedAt,
			finishedAt: finishedAt,
			createdAt: availableAt
		)
	}
}

private extension SQLiteAIStoreTests {

	static func execute(_ sql: String, at path: String) throws {
		var database: OpaquePointer?
		guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
			throw NSError(domain: "SQLiteAIStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open \(path)"])
		}
		defer {
			sqlite3_close(database)
		}
		guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
			throw NSError(domain: "SQLiteAIStoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
		}
	}

	static func columnNames(inTable table: String, at path: String) throws -> [String] {
		try queryStrings(sql: "pragma table_info(\(table));", column: 1, at: path)
	}

	static func indexNames(at path: String) throws -> Set<String> {
		Set(try queryStrings(sql: "select name from sqlite_master where type = 'index';", column: 0, at: path))
	}

	static func indexNamesFromPragma(table: String, at path: String) throws -> Set<String> {
		Set(try queryStrings(sql: "pragma index_list(\(table));", column: 1, at: path))
	}

	static func queryStrings(sql: String, column: Int32, at path: String) throws -> [String] {
		var database: OpaquePointer?
		guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
			throw NSError(domain: "SQLiteAIStoreTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to open \(path)"])
		}
		defer {
			sqlite3_close(database)
		}
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
			throw NSError(domain: "SQLiteAIStoreTests", code: 4, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
		}
		defer {
			sqlite3_finalize(statement)
		}
		var values: [String] = []
		while sqlite3_step(statement) == SQLITE_ROW {
			guard let text = sqlite3_column_text(statement, column) else {
				continue
			}
			values.append(String(cString: text))
		}
		return values
	}

	static func removeDatabase(at path: String) {
		let fileManager = FileManager.default
		try? fileManager.removeItem(atPath: path)
		try? fileManager.removeItem(atPath: path + "-wal")
		try? fileManager.removeItem(atPath: path + "-shm")
	}
}

private final class JobNotificationRecorder: @unchecked Sendable {

	private let lock = NSLock()
	private var recordedCount = 0
	private var payloadsEmpty = true

	var count: Int {
		lock.withLock {
			recordedCount
		}
	}

	var allPayloadsEmpty: Bool {
		lock.withLock {
			payloadsEmpty
		}
	}

	func reset() {
		lock.withLock {
			recordedCount = 0
		}
	}

	func record(object: Any?, userInfo: [AnyHashable: Any]?) {
		lock.withLock {
			recordedCount += 1
			if object != nil || userInfo != nil {
				payloadsEmpty = false
			}
		}
	}
}
