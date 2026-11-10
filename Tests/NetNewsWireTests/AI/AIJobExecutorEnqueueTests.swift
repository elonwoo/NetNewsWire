//
//  AIJobExecutorEnqueueTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite(.serialized)
@MainActor
final class AIJobExecutorEnqueueTests {

	private var store: SQLiteAIStore!
	private var queue: AIQueue!
	private let databasePath: String
	private let config = AIConfig(model: "test-model")

	init() {
		self.databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIJobExecutorEnqueueTests-\(UUID().uuidString).sqlite")
			.path
		self.store = SQLiteAIStore(databasePath: databasePath)
		self.queue = AIQueue(store: store)
	}

	deinit {
		// Release the store first so its SQLite connection is closed before the
		// files are removed; unlinking an open database logs "vnode unlinked while in use".
		queue = nil
		store = nil

		let fileManager = FileManager.default
		try? fileManager.removeItem(atPath: databasePath)
		try? fileManager.removeItem(atPath: databasePath + "-wal")
		try? fileManager.removeItem(atPath: databasePath + "-shm")
	}

	// MARK: - Download notification path

	@Test func enqueueRewriteSkipsLegacyAndCurrentRewrites() async throws {
		let article = englishArticle(id: "legacy")
		let executor = makeExecutor(source: AICatchUpSource())

		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.legacyRewrite(for: article)))
		await executor.enqueueRewrite(for: article, origin: .auto)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)

		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.rewrite(for: article)))
		await executor.enqueueRewrite(for: article, origin: .auto)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
	}

	@Test func enqueueRewriteQueuesChangedAndMissingRewrites() async throws {
		let executor = makeExecutor(source: AICatchUpSource())

		let changed = englishArticle(id: "changed")
		try await store.saveRewrite(rewrite(article: changed, hash: "stale"))
		await executor.enqueueRewrite(for: changed)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains("changed"))

		let missing = englishArticle(id: "missing")
		await executor.enqueueRewrite(for: missing)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains("missing"))
	}

	@Test func enqueueForNewArticlesDoesNotQueueLegacyRewrites() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}

		let legacy = englishArticle(id: "legacy-download", publishedAt: Date())
		let changed = englishArticle(id: "changed-download", publishedAt: Date())
		try await store.saveRewrite(rewrite(article: legacy, hash: AIContentHash.legacyRewrite(for: legacy)))
		try await store.saveRewrite(rewrite(article: changed, hash: "stale"))

		let executor = makeExecutor(source: AICatchUpSource())
		await executor.enqueueForNewArticles([legacy, changed])

		let active = try await store.activeJobArticleIDs(kinds: [.rewrite])
		#expect(!active.contains("legacy-download"))
		#expect(active.contains("changed-download"))
	}

	// MARK: - Catch-up path

	@Test func catchUpSkipsLegacyAndQueuesChangedRewrites() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}

		let article = englishArticle(id: "catch-up", publishedAt: Date())
		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.legacyRewrite(for: article)))
		let executor = makeExecutor(source: AICatchUpSource(articles: [article]))

		await executor.catchUpMissedWork()
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)

		try await store.saveRewrite(rewrite(article: article, hash: "stale"))
		await executor.catchUpMissedWork()
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains("catch-up"))
	}

	// MARK: - Body translation

	@Test func bodyTranslationIsNotNeededWhenBlocksExist() async throws {
		let article = englishArticle(id: "body")
		let translation = AI.Translation(
			articleID: article.id,
			blocks: [TranslationBlock(index: 0, source: "Hello", target: "你好")],
			model: "old-model",
			provider: "magpie",
			contentHash: "old-hash",
			createdAt: Date(),
			updatedAt: Date()
		)
		try await store.saveTranslation(translation)

		let executor = makeExecutor(source: AICatchUpSource())
		let result = await executor.enqueueBodyTranslation(for: article)

		#expect(result == .notNeeded)
		#expect(try await store.activeJobArticleIDs(kinds: [.bodyTranslation]).isEmpty)
	}

	// MARK: - Titles

	@Test func titleTranslationWritesOnlyTheTitleHash() async throws {
		let client = TitleClient()
		let engine = AIEngine(store: store, client: client, config: config)
		let articles = [AIArticle(id: "title", title: "Title", contentText: "Body")]

		_ = try await engine.translateTitles(articles)

		let stored = try #require(try await store.translation(for: "title"))
		#expect(stored.contentHash == ContentFingerprint.title(for: articles[0]))
		#expect(!stored.contentHash.hasPrefix("r2:"))
		#expect(!stored.contentHash.hasPrefix("b2:"))
	}

	// MARK: - Chinese language gate

	@Test func newArticlesSkipChineseWithoutOverride() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}
		let article = chineseArticle(id: "zh-new", publishedAt: Date())
		let executor = makeExecutor(source: AICatchUpSource())

		await executor.enqueueForNewArticles([article])

		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).isEmpty)
	}

	@Test func newArticlesQueueChineseWhenFeedIsOverridden() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}
		let article = chineseArticle(id: "zh-new", publishedAt: Date())
		let executor = makeExecutor(source: AICatchUpSource(), chineseAllowedFeedIDs: ["zh-feed"])

		await executor.enqueueForNewArticles([article])

		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains(article.id))
		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).contains(article.id))
	}

	@Test func catchUpSkipsChineseWithoutOverride() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}
		let article = chineseArticle(id: "zh-catch-up", publishedAt: Date())
		let executor = makeExecutor(source: AICatchUpSource(articles: [article]))

		await executor.catchUpMissedWork()

		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).isEmpty)
	}

	@Test func catchUpQueuesChineseWhenFeedIsOverridden() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}
		let article = chineseArticle(id: "zh-catch-up", publishedAt: Date())
		let executor = makeExecutor(source: AICatchUpSource(articles: [article]), chineseAllowedFeedIDs: ["zh-feed"])

		await executor.catchUpMissedWork()

		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains(article.id))
		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).contains(article.id))
	}

	@Test func titleTranslationsSkipChineseWithoutOverride() async throws {
		let article = chineseArticle(id: "zh-title")
		let executor = makeExecutor(source: AICatchUpSource())

		await executor.enqueueTitleTranslations(for: [article])

		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).isEmpty)
	}

	@Test func titleTranslationsQueueChineseWhenFeedIsOverridden() async throws {
		let article = chineseArticle(id: "zh-title")
		let executor = makeExecutor(source: AICatchUpSource(), chineseAllowedFeedIDs: ["zh-feed"])

		await executor.enqueueTitleTranslations(for: [article])

		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).contains(article.id))
	}

	@Test func titleTranslationByIDSkipsChineseWithoutOverride() async throws {
		let article = chineseArticle(id: "zh-title-by-id")
		let executor = makeExecutor(source: AICatchUpSource(), resolver: FixedResolver(article: article))

		await executor.enqueueTitleTranslation(articleID: article.id)

		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).isEmpty)
	}

	@Test func bodyTranslationSkipsChineseWithoutOverride() async throws {
		let article = chineseArticle(id: "zh-body")
		let executor = makeExecutor(source: AICatchUpSource())

		let result = await executor.enqueueBodyTranslation(for: article)

		#expect(result == .notNeeded)
		#expect(try await store.activeJobArticleIDs(kinds: [.bodyTranslation]).isEmpty)
	}

	@Test func bodyTranslationQueuesChineseWhenFeedIsOverridden() async throws {
		let article = chineseArticle(id: "zh-body")
		let executor = makeExecutor(source: AICatchUpSource(), chineseAllowedFeedIDs: ["zh-feed"])

		let result = await executor.enqueueBodyTranslation(for: article)

		#expect(result == .enqueued)
		#expect(try await store.activeJobArticleIDs(kinds: [.bodyTranslation]).contains(article.id))
	}

	// MARK: - Manual entry

	@Test func manualRewriteEntrySkipsChineseWithoutOverride() async throws {
		let article = chineseArticle(id: "zh-manual")
		let executor = makeExecutor(source: AICatchUpSource(), resolver: FixedResolver(article: article))

		await executor.enqueueRewrite(articleID: article.id)

		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
	}

	@Test func manualRewriteEntryQueuesChineseWhenFeedIsOverridden() async throws {
		let article = chineseArticle(id: "zh-manual")
		let executor = makeExecutor(source: AICatchUpSource(), chineseAllowedFeedIDs: ["zh-feed"], resolver: FixedResolver(article: article))

		await executor.enqueueRewrite(articleID: article.id)

		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains(article.id))
	}

	@Test func manualRewriteEnqueueLogsManualOrigin() async throws {
		let article = englishArticle(id: "manual-origin")
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: RewriteRecordingClient(),
			taskLog: log
		)

		let result = await executor.enqueueRewrite(for: article, origin: .manual)
		#expect(result == .enqueued)

		let job = try #require(try await executor.claimNextJob())
		await executor.runJob(job)

		let events = await log.terminalEvents
		#expect(events.count == 1)
		#expect(events.first?.trigger == .manual)
	}

	@Test func repeatedManualRewriteClickLogsAlreadyInFlight() async throws {
		let article = englishArticle(id: "manual-repeat")
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: NoCallClient(),
			taskLog: log
		)

		let first = await executor.enqueueRewrite(for: article, origin: .manual)
		let second = await executor.enqueueRewrite(for: article, origin: .manual)

		#expect(first == .enqueued)
		#expect(second == .alreadyInFlight)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]) == Set([article.id]))

		let events = await log.attemptEvents
		#expect(events.count == 1)
		#expect(events.first?.kind == .rewrite)
		#expect(events.first?.articleID == article.id)
		#expect(events.first?.trigger == .manual)
		#expect(events.first?.outcome == .skipped)
		#expect(events.first?.reason == .alreadyInFlight)
	}

	@Test func manualRewriteEnqueuesEvenWhenTheStoredRewriteIsCurrent() async throws {
		let article = englishArticle(id: "manual-current")
		let executor = makeExecutor(source: AICatchUpSource())
		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.rewrite(for: article)))

		let result = await executor.enqueueRewrite(for: article, origin: .manual)

		#expect(result == .enqueued)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains(article.id))
	}

	@Test func automaticRewriteSkipsWhenTheStoredRewriteIsCurrent() async throws {
		let article = englishArticle(id: "auto-current")
		let executor = makeExecutor(source: AICatchUpSource())
		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.rewrite(for: article)))

		let result = await executor.enqueueRewrite(for: article, origin: .auto)

		#expect(result == .alreadyUpToDate)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
	}

	@Test func manualRewriteRunsAtInteractivePriority() async throws {
		let executor = makeExecutor(source: AICatchUpSource())
		let manual = englishArticle(id: "priority-manual")
		let auto = englishArticle(id: "priority-auto")

		await executor.enqueueRewrite(for: manual, origin: .manual)
		await executor.enqueueRewrite(for: auto, origin: .auto)

		let first = try #require(try await executor.claimNextJob(allowedKinds: [.rewrite]))
		#expect(first.articleID == manual.id)
		#expect(first.priority == 100)

		let second = try #require(try await executor.claimNextJob(allowedKinds: [.rewrite]))
		#expect(second.articleID == auto.id)
		#expect(second.priority == 10)
	}

	@Test func executionCompletesAChineseJobSilently() async throws {
		let article = chineseArticle(id: "zh-execute")
		let now = Date()
		let job = AIJob(
			id: "rewrite:\(article.id)",
			articleID: article.id,
			kind: .rewrite,
			priority: 100,
			availableAt: now,
			createdAt: now
		)
		try await store.enqueue(job)
		let client = CountingClient()
		let notificationCenter = NotificationCenter()
		let failureCounter = FailureCounter()
		let token = notificationCenter.addObserver(forName: .aiJobFailed, object: nil, queue: nil) { _ in
			failureCounter.increment()
		}
		defer {
			notificationCenter.removeObserver(token)
		}
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			notificationCenter: notificationCenter
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(client.callCount == 0)
		#expect(failureCounter.value == 0)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
		#expect(try await store.inventory().completedJobArticleIDs.contains(article.id))
	}

	// MARK: - Summary rewrites

	@Test func summaryRewriteWithoutFullTextFailsPermanentlyWithoutRetry() async throws {
		let article = summaryArticle(id: "summary-missing", publishedAt: Date())
		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.rewrite(for: article)))
		let job = AIJob(
			id: "rewrite:\(article.id)",
			articleID: article.id,
			kind: .rewrite,
			priority: 100,
			availableAt: Date(),
			createdAt: Date()
		)
		try await store.enqueue(job)
		let client = CountingClient()
		let fetcher = RecordingFullTextFetcher(outcome: .unavailable("网页返回状态码 500"))
		let notificationCenter = NotificationCenter()
		let failureCounter = FailureCounter()
		let rewriteRemovedCounter = FailureCounter()
		let failureToken = notificationCenter.addObserver(forName: .aiJobFailed, object: nil, queue: nil) { _ in
			failureCounter.increment()
		}
		let removedToken = notificationCenter.addObserver(forName: .aiRewriteRemoved, object: nil, queue: nil) { _ in
			rewriteRemovedCounter.increment()
		}
		defer {
			notificationCenter.removeObserver(failureToken)
			notificationCenter.removeObserver(removedToken)
		}
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher,
			notificationCenter: notificationCenter
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(fetcher.fetchCount == 1)
		#expect(client.callCount == 0)
		#expect(failureCounter.value == 1)
		#expect(rewriteRemovedCounter.value == 1)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
		#expect(try await store.rewrite(for: article.id) == nil)

		let failed = try await store.recentJobs(status: .failed, since: .distantPast, limit: 10)
		#expect(failed.first?.articleID == article.id)
		#expect(failed.first?.lastError == "原文为摘要，未获取到全文，已跳过改写：网页返回状态码 500")
	}

	@Test func rejectedSummaryRewriteDoesNotRestoreTheOldTeaserText() async throws {
		let article = summaryArticle(id: "summary-quality", publishedAt: Date())
		let old = rewrite(article: article, hash: AIContentHash.rewrite(for: article))
		try await store.saveRewrite(old)
		let enriched = AIArticle(
			id: article.id,
			title: article.title,
			contentHTML: "<p>ENRICHED-MARKER \(String(repeating: "body ", count: 60))</p>",
			url: article.url,
			feedID: article.feedID,
			publishedAt: article.publishedAt
		)
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let client = ShortRewriteClient()
		let fetcher = RecordingFullTextFetcher(outcome: .enriched(enriched))
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(fetcher.fetchCount == 1)
		#expect(client.callCount == 1)
		#expect(try await store.rewrite(for: article.id) == nil)
	}

	@Test func failedSummaryRewriteKeepsTheFullTextRewrite() async throws {
		let article = shortEnglishArticle(id: "summary-ft-fetch", publishedAt: Date())
		let fullTextHash = "ft:" + AIContentHash.rewrite(for: article)
		let old = rewrite(article: article, hash: fullTextHash, body: "已有全文改写")
		try await store.saveRewrite(old)
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let notificationCenter = NotificationCenter()
		let removedCounter = FailureCounter()
		let removedToken = notificationCenter.addObserver(forName: .aiRewriteRemoved, object: nil, queue: nil) { _ in
			removedCounter.increment()
		}
		defer {
			notificationCenter.removeObserver(removedToken)
		}
		let fetcher = RecordingFullTextFetcher(outcome: .unavailable("网页返回状态码 500"))
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: NoCallClient(),
			fullTextFetcher: fetcher,
			notificationCenter: notificationCenter
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let stored = try #require(try await store.rewrite(for: article.id))
		#expect(stored.bodyMarkdown == "已有全文改写")
		#expect(stored.contentHash == fullTextHash)
		#expect(removedCounter.value == 0)
		let failed = try await store.recentJobs(status: .failed, since: .distantPast, limit: 10)
		#expect(failed.first(where: { $0.articleID == article.id })?.lastError == "原文为摘要，未获取到全文，已跳过改写：网页返回状态码 500")
	}

	@Test func rejectedSummaryRewriteRestoresTheFullTextRewrite() async throws {
		let article = shortEnglishArticle(id: "summary-ft-quality", publishedAt: Date())
		let fullTextHash = "ft:" + AIContentHash.rewrite(for: article)
		let old = rewrite(article: article, hash: fullTextHash, body: "已有全文改写")
		try await store.saveRewrite(old)
		let enriched = AIArticle(
			id: article.id,
			title: article.title,
			contentHTML: "<p>ENRICHED-MARKER \(String(repeating: "body ", count: 60))</p>",
			url: article.url,
			feedID: article.feedID,
			publishedAt: article.publishedAt
		)
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let storedCounter = FailureCounter()
		let storedToken = NotificationCenter.default.addObserver(forName: .aiRewriteStored, object: nil, queue: nil) { _ in
			storedCounter.increment()
		}
		defer {
			NotificationCenter.default.removeObserver(storedToken)
		}
		let client = ShortRewriteClient()
		let fetcher = RecordingFullTextFetcher(outcome: .enriched(enriched))
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let stored = try #require(try await store.rewrite(for: article.id))
		#expect(stored.bodyMarkdown == "已有全文改写")
		#expect(stored.contentHash == fullTextHash)
		#expect(storedCounter.value == 2)
	}

	@Test func failedLongArticleRewriteKeepsTheOldRewrite() async throws {
		let article = englishArticle(id: "long-failure", publishedAt: Date())
		let old = rewrite(article: article, hash: "stale")
		try await store.saveRewrite(old)
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let client = CountingClient()
		let fetcher = RecordingFullTextFetcher(outcome: .unavailable("should not be used"))
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(fetcher.fetchCount == 0)
		#expect(client.callCount == 1)
		let stored = try #require(try await store.rewrite(for: article.id))
		#expect(stored.bodyMarkdown == old.bodyMarkdown)
		#expect(stored.contentHash == old.contentHash)
	}

	@Test func summaryRewriteUsesExtractedHTMLAndKeepsFeedFingerprint() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}

		let article = summaryArticle(id: "summary-success", publishedAt: Date())
		let enriched = AIArticle(
			id: article.id,
			title: article.title,
			contentHTML: "<p>ENRICHED-MARKER \(String(repeating: "body ", count: 60))</p>",
			url: article.url,
			feedID: article.feedID,
			publishedAt: article.publishedAt
		)
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let client = RewriteRecordingClient()
		let fetcher = RecordingFullTextFetcher(outcome: .enriched(enriched))
		let executor = makeExecutor(
			source: AICatchUpSource(articles: [article]),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(fetcher.fetchCount == 1)
		#expect(client.callCount == 1)
		#expect(client.lastUserMessage?.contains("ENRICHED-MARKER") == true)

		let stored = try #require(try await store.rewrite(for: article.id))
		#expect(stored.contentHash == "ft:" + AIContentHash.rewrite(for: article))
		#expect(stored.contentHash != AIContentHash.rewrite(for: article))

		await executor.catchUpMissedWork()
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
	}

	@Test func longArticleNeverAsksForFullText() async throws {
		let article = englishArticle(id: "long-article", publishedAt: Date())
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let client = RewriteRecordingClient()
		let fetcher = RecordingFullTextFetcher(outcome: .unavailable("should not be used"))
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(fetcher.fetchCount == 0)
		#expect(client.callCount == 1)
		#expect(try await store.rewrite(for: article.id) != nil)
		#expect(try await store.inventory().completedJobArticleIDs.contains(article.id))
	}

	@Test func notApplicableKindKeepsTheFeedRewrite() async throws {
		let article = AIArticle(
			id: "short-paper",
			title: "English paper title",
			contentText: "Short paper abstract.",
			url: "https://arxiv.org/abs/2501.00001",
			feedID: "feed",
			publishedAt: Date()
		)
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let client = RewriteRecordingClient()
		let fetcher = RecordingFullTextFetcher(outcome: .notApplicable)
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(fetcher.fetchCount == 1)
		#expect(client.callCount == 1)
		let stored = try #require(try await store.rewrite(for: article.id))
		#expect(stored.contentHash == AIContentHash.rewrite(for: article))
		#expect(!stored.contentHash.hasPrefix("ft:"))
		#expect(try await store.inventory().completedJobArticleIDs.contains(article.id))
	}

	@Test func fullTextRewriteRunsAgainWhenForced() async throws {
		let article = summaryArticle(id: "summary-forced", publishedAt: Date())
		let enriched = AIArticle(
			id: article.id,
			title: article.title,
			contentHTML: "<p>ENRICHED-MARKER \(String(repeating: "body ", count: 60))</p>",
			url: article.url,
			feedID: article.feedID,
			publishedAt: article.publishedAt
		)
		let client = RewriteRecordingClient()
		let fetcher = RecordingFullTextFetcher(outcome: .enriched(enriched))
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let firstClaim = try #require(try await executor.claimNextJob())
		await executor.runJob(firstClaim)

		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: Date(), createdAt: Date()))
		let secondClaim = try #require(try await executor.claimNextJob())
		await executor.runJob(secondClaim)

		#expect(fetcher.fetchCount == 2)
		#expect(client.callCount == 2)
		let stored = try #require(try await store.rewrite(for: article.id))
		#expect(stored.contentHash == "ft:" + AIContentHash.rewrite(for: article))
	}

	@Test func catchUpRequeuesShortOldRewriteForMigration() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}
		let article = AIArticle(
			id: "short-migration",
			title: "English title",
			contentText: String(repeating: "a", count: 800),
			url: "https://example.com/short-migration",
			publishedAt: Date()
		)
		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.rewrite(for: article)))
		let executor = makeExecutor(source: AICatchUpSource(articles: [article]))

		await executor.catchUpMissedWork()

		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains(article.id))
	}

	@Test(arguments: ["News", "Hi"])
	func manualRewriteRejectsTooShortFeedBody(_ body: String) async throws {
		let article = AIArticle(
			id: "too-short-\(body.lowercased())",
			title: "English title",
			contentText: body,
			url: "https://example.com/too-short",
			feedID: "feed",
			publishedAt: Date()
		)
		let loader = PageCountingLoader(html: Self.siteInfoPage())
		let fetcher = AIFullTextFetcher(loader: loader)
		let client = RewriteRecordingClient()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		await executor.enqueueRewrite(articleID: article.id)
		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(loader.callCount == 0)
		#expect(client.callCount == 0)
		#expect(try await store.rewrite(for: article.id) == nil)
		let failed = try await store.recentJobs(status: .failed, since: .distantPast, limit: 20)
		#expect(failed.first(where: { $0.articleID == article.id })?.lastError == "原文过短，已跳过改写")
	}

	@Test func normalFeedBodyStillFetches() async throws {
		let article = summaryArticle(id: "normal-body", publishedAt: Date())
		let loader = PageCountingLoader(html: Self.articlePage())
		let fetcher = AIFullTextFetcher(loader: loader)
		let client = RewriteRecordingClient()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client,
			fullTextFetcher: fetcher
		)

		await executor.enqueueRewrite(articleID: article.id)
		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		#expect(loader.callCount == 1)
		#expect(client.callCount == 1)
		#expect(try await store.rewrite(for: article.id) != nil)
	}

	// MARK: - Acceptance gate

	@Test func autoWorkGateBlocksAutomaticPathsAndClaims() async throws {
		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}
		let article = englishArticle(id: "en-gated", publishedAt: Date())
		let executor = makeExecutor(source: AICatchUpSource(articles: [article]), autoWorkDisabled: true)

		await executor.enqueueForNewArticles([article])
		await executor.catchUpMissedWork()
		let bodyResult = await executor.enqueueBodyTranslation(for: article)

		#expect(bodyResult == .notNeeded)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)
		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).isEmpty)
		#expect(try await store.activeJobArticleIDs(kinds: [.bodyTranslation]).isEmpty)

		let now = Date()
		try await store.enqueue(AIJob(id: "rewrite:pending-gated", articleID: "pending-gated", kind: .rewrite, priority: 100, availableAt: now, createdAt: now))
		#expect(try await executor.claimNextJob() == nil)
	}

	@Test func autoWorkGateOffStillClaimsJobs() async throws {
		let article = englishArticle(id: "en-claim", publishedAt: Date())
		let executor = makeExecutor(source: AICatchUpSource(), autoWorkDisabled: false)
		let now = Date()
		try await store.enqueue(AIJob(id: "rewrite:\(article.id)", articleID: article.id, kind: .rewrite, priority: 100, availableAt: now, createdAt: now))

		let claimed = try #require(try await executor.claimNextJob())
		#expect(claimed.articleID == article.id)
	}

	// MARK: - Lanes

	@Test func laneClaimsOnlySeeTheirOwnKinds() async throws {
		let article = englishArticle(id: "lane-claim")
		let executor = makeExecutor(source: AICatchUpSource())
		let now = Date()
		try await store.enqueue(AIJob(id: "rewrite:lane", articleID: article.id, kind: .rewrite, priority: 100, availableAt: now, createdAt: now))
		try await store.enqueue(AIJob(id: "title:lane", articleID: article.id, kind: .titleTranslation, priority: 0, availableAt: now, createdAt: now))

		let title = try #require(try await executor.claimNextJob(allowedKinds: [.bodyTranslation, .titleTranslation]))
		#expect(title.id == "title:lane")
		let rewrite = try #require(try await executor.claimNextJob(allowedKinds: [.rewrite]))
		#expect(rewrite.id == "rewrite:lane")
	}

	@Test func autoWorkGateAlsoBlocksLaneClaims() async throws {
		let executor = makeExecutor(source: AICatchUpSource(), autoWorkDisabled: true)
		let now = Date()
		try await store.enqueue(AIJob(id: "rewrite:gated-lane", articleID: "gated-lane", kind: .rewrite, priority: 100, availableAt: now, createdAt: now))

		#expect(try await executor.claimNextJob(allowedKinds: [.rewrite]) == nil)
	}

	@Test func stopDoesNotLeaveAClaimedJobRunning() async throws {
		let article = AIArticle(id: "stop-running", title: "English title", contentText: "Body")
		let client = BlockingClient(articleID: article.id)
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: client
		)
		let now = Date()
		try await store.enqueue(AIJob(id: "title:\(article.id)", articleID: article.id, kind: .titleTranslation, priority: 100, availableAt: now, createdAt: now))

		executor.start()
		await client.waitUntilStarted()
		executor.stop()
		client.release()

		let completed = await waitFor {
			(try? await self.store.inventory().completedJobArticleIDs.contains(article.id)) ?? false
		}
		#expect(completed)
		#expect(try await store.activeJobArticleIDs(kinds: [.titleTranslation]).isEmpty)
	}
	// MARK: - Task log

	@Test func taskLogRecordsTooShortBodyAsSkipped() async throws {
		let article = AIArticle(
			id: "log-too-short",
			title: "English title",
			contentText: "News",
			url: "https://example.com/log-too-short",
			feedID: "feed",
			publishedAt: Date()
		)
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: NoCallClient(),
			fullTextFetcher: AIFullTextFetcher(loader: PageCountingLoader(html: Self.siteInfoPage())),
			taskLog: log
		)

		await executor.enqueueRewrite(articleID: article.id)
		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let events = await log.terminalEvents
		#expect(events.count == 1)
		#expect(events.first?.outcome == .skipped)
		#expect(events.first?.reason == .bodyTooShort)
	}

	@Test func taskLogRecordsFullTextUnavailableAsSkipped() async throws {
		let article = summaryArticle(id: "log-full-text", publishedAt: Date())
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: NoCallClient(),
			fullTextFetcher: RecordingFullTextFetcher(outcome: .unavailable("网页返回状态码 500")),
			taskLog: log
		)

		await executor.enqueueRewrite(articleID: article.id)
		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let events = await log.terminalEvents
		#expect(events.count == 1)
		#expect(events.first?.outcome == .skipped)
		#expect(events.first?.reason == .fullTextUnavailable)
	}

	@Test func taskLogRecordsStoredRewriteWithOutputLength() async throws {
		let article = englishArticle(id: "log-stored", publishedAt: Date())
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: RewriteRecordingClient(),
			taskLog: log
		)

		await executor.enqueueRewrite(articleID: article.id)
		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let events = await log.terminalEvents
		#expect(events.count == 1)
		#expect(events.first?.outcome == .stored)
		#expect(events.first?.trigger == .manual)
		#expect(events.first?.attempts == 1)
		#expect((events.first?.outputCharacters ?? 0) > 0)
		#expect((events.first?.inputCharacters ?? 0) > 0)
		#expect((events.first?.feedCharacters ?? 0) > 0)
		#expect(events.first?.model == "test-model")
	}

	@Test func taskLogWritesOneEventForASuccessfulRetry() async throws {
		let article = englishArticle(id: "log-retry", publishedAt: Date())
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: RewriteRecordingClient(),
			taskLog: log
		)
		let job = AIJob(
			id: "rewrite:\(article.id)",
			articleID: article.id,
			kind: .rewrite,
			priority: 100,
			attempts: 1,
			availableAt: Date(),
			createdAt: Date()
		)
		try await store.enqueue(job)

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let events = await log.terminalEvents
		#expect(events.count == 1)
		#expect(events.first?.outcome == .stored)
		#expect(events.first?.attempts == 2)
	}

	@Test func taskLogRecordsCachedBodyTranslation() async throws {
		let article = englishArticle(id: "log-cached-body", publishedAt: Date())
		let translation = AI.Translation(
			articleID: article.id,
			titleZh: "中文标题",
			summaryZh: nil,
			blocks: [
				TranslationBlock(index: 0, source: "source", target: "译文一"),
				TranslationBlock(index: 1, source: "source", target: "译文二")
			],
			model: "old-model",
			provider: "magpie",
			contentHash: AIContentHash.body(for: article),
			createdAt: Date(),
			updatedAt: Date()
		)
		try await store.saveTranslation(translation)
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: NoCallClient(),
			taskLog: log
		)
		try await store.enqueue(AIJob(id: "body:\(article.id)", articleID: article.id, kind: .bodyTranslation, priority: 100, availableAt: Date(), createdAt: Date()))

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let events = await log.terminalEvents
		#expect(events.count == 1)
		#expect(events.first?.outcome == .cached)
		#expect(events.first?.blocks == 2)
		#expect((events.first?.outputCharacters ?? 0) > 0)
	}

	@Test func taskLogRecordsQualityRejectionOnlyAfterItBecomesTerminal() async throws {
		let article = englishArticle(id: "log-quality-retry", publishedAt: Date())
		let rejectedLog = MemoryTaskLog()
		let rejectedExecutor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: ShortRewriteClient(),
			taskLog: rejectedLog
		)

		await rejectedExecutor.enqueueRewrite(articleID: article.id)
		let rejectedJob = try #require(try await rejectedExecutor.claimNextJob())
		await rejectedExecutor.runJob(rejectedJob)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).contains(article.id))
		let rejectedEvents = await rejectedLog.terminalEvents
		#expect(rejectedEvents.isEmpty)

		let succeededLog = MemoryTaskLog()
		let succeededExecutor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: RewriteRecordingClient(),
			taskLog: succeededLog
		)
		await succeededExecutor.enqueueRewrite(articleID: article.id)
		let succeededJob = try #require(try await succeededExecutor.claimNextJob())
		await succeededExecutor.runJob(succeededJob)

		let succeededEvents = await succeededLog.terminalEvents
		#expect(succeededEvents.count == 1)
		#expect(succeededEvents.first?.outcome == .stored)
	}

	@Test func taskLogRecordsFullyCachedTitleBatch() async throws {
		let article = englishArticle(id: "log-cached-title", publishedAt: Date())
		try await store.saveTitleTranslation(
			articleID: article.id,
			titleZh: "中文标题",
			model: "old-model",
			contentHash: AIContentHash.title(for: article),
			at: Date()
		)
		let log = MemoryTaskLog()
		let executor = makeExecutor(
			source: AICatchUpSource(),
			resolver: FixedResolver(article: article),
			client: NoCallClient(),
			taskLog: log
		)
		try await store.enqueue(AIJob(id: "title:\(article.id)", articleID: article.id, kind: .titleTranslation, priority: 50, availableAt: Date(), createdAt: Date()))

		let claimed = try #require(try await executor.claimNextJob())
		await executor.runJob(claimed)

		let events = await log.terminalEvents
		#expect(events.count == 1)
		#expect(events.first?.outcome == .cached)
		#expect(events.first?.batchSize == 1)
		#expect((events.first?.outputCharacters ?? 0) > 0)
	}
}

// MARK: - Helpers

@MainActor
private extension AIJobExecutorEnqueueTests {

	func englishArticle(id: String, publishedAt: Date? = nil) -> AIArticle {
		AIArticle(
			id: id,
			title: "English title",
			contentText: String(repeating: "a", count: 2500),
			publishedAt: publishedAt
		)
	}

	func summaryArticle(id: String, publishedAt: Date? = nil) -> AIArticle {
		AIArticle(
			id: id,
			title: "English summary title",
			contentText: "Short feed summary body.",
			url: "https://example.com/\(id)",
			feedID: "feed",
			publishedAt: publishedAt
		)
	}

	func shortEnglishArticle(id: String, publishedAt: Date? = nil) -> AIArticle {
		AIArticle(
			id: id,
			title: "English title",
			contentText: String(repeating: "a", count: 816),
			url: "https://example.com/\(id)",
			feedID: "feed",
			publishedAt: publishedAt
		)
	}

	func chineseArticle(id: String, publishedAt: Date? = nil, feedID: String = "zh-feed") -> AIArticle {
		AIArticle(
			id: id,
			title: "中文标题",
			contentText: String(repeating: "中", count: 2500),
			feedID: feedID,
			publishedAt: publishedAt
		)
	}

	func rewrite(article: AIArticle, hash: String, body: String = "已有改写") -> AI.Rewrite {
		AI.Rewrite(
			articleID: article.id,
			title: article.title,
			bodyMarkdown: body,
			model: "old-model",
			contentHash: hash,
			createdAt: Date(),
			updatedAt: Date()
		)
	}

	static func siteInfoPage() -> String {
		"<html><body><div id=\"siteinfo\"><p>\(String(repeating: "Site footer ", count: 200))</p></div></body></html>"
	}

	static func articlePage() -> String {
		"""
		<html><body><article>
		<p>Short feed summary body. \(String(repeating: "content ", count: 80))</p>
		<p>\(String(repeating: "more ", count: 80))</p>
		</article></body></html>
		"""
	}

	/// Polls until `condition` is true or the timeout elapses. The lanes run on
	/// the main actor, so the test yields between checks.
	func waitFor(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if await condition() {
				return true
			}
			try? await Task.sleep(for: .milliseconds(20))
		}
		return await condition()
	}

	func makeExecutor(
		source: AICatchUpSource,
		chineseAllowedFeedIDs: Set<String> = [],
		autoWorkDisabled: Bool = false,
		resolver: AIArticleResolving = EmptyResolver(),
		client: AIClient = NoCallClient(),
		fullTextFetcher: AIFullTextFetching = NoFetchFullTextFetcher(),
		notificationCenter: NotificationCenter = NotificationCenter(),
		taskLog: AITaskLogging = MemoryTaskLog()
	) -> AIJobExecutor {
		let engine = AIEngine(store: store, client: client, config: config)
		let store: SQLiteAIStore = self.store
		let config = self.config
		return AIJobExecutor(
			store: store,
			queue: queue,
			resolver: resolver,
			fullTextFetcher: fullTextFetcher,
			services: {
				AIJobServices(
					translation: AITranslationService(store: store, engine: engine, config: config),
					rewrite: AIRewriteService(store: store, engine: engine),
					model: config.model
				)
			},
			isConfigured: { true },
			notificationCenter: notificationCenter,
			autoStart: false,
			catchUpSourceProvider: { source },
			chineseAllowedFeedIDsProvider: { chineseAllowedFeedIDs },
			autoWorkDisabled: autoWorkDisabled,
			taskLog: taskLog
		)
	}
}

actor MemoryTaskLog: AITaskLogging {

	private(set) var terminalEvents: [AITaskTerminalEvent] = []
	private(set) var attemptEvents: [AITaskAttemptEvent] = []

	func recordTerminal(_ event: AITaskTerminalEvent) {
		terminalEvents.append(event)
	}

	func recordAttempt(_ event: AITaskAttemptEvent) {
		attemptEvents.append(event)
	}
}

private final class NoCallClient: AIClient, Sendable {

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		throw AIClientError.invalidResponse
	}
}

private struct NoFetchFullTextFetcher: AIFullTextFetching {

	nonisolated func isLikelySummary(_ article: AIArticle) async -> Bool {
		false
	}

	nonisolated func enrichedArticle(for article: AIArticle) async -> AIFullTextOutcome {
		.unavailable("disabled")
	}
}

private final class PageCountingLoader: SourceHTTPLoading, @unchecked Sendable {

	private let html: String
	private let lock = NSLock()
	private var storedCallCount = 0

	init(html: String) {
		self.html = html
	}

	var callCount: Int {
		lock.withLock {
			storedCallCount
		}
	}

	func load(_ request: SourceHTTPRequest) async throws -> SourceHTTPResponse {
		lock.withLock {
			storedCallCount += 1
		}
		return SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
	}
}

private final class RecordingFullTextFetcher: AIFullTextFetching, @unchecked Sendable {
	private let outcome: AIFullTextOutcome
	private let lock = NSLock()
	private var storedFetchCount = 0

	init(outcome: AIFullTextOutcome) {
		self.outcome = outcome
	}

	var fetchCount: Int {
		lock.withLock {
			storedFetchCount
		}
	}

	@concurrent nonisolated func isLikelySummary(_ article: AIArticle) async -> Bool {
		let count = (article.contentText ?? "").reduce(0) { count, character in
			character.isWhitespace ? count : count + 1
		}
		return count < 1500
	}

	@concurrent nonisolated func enrichedArticle(for article: AIArticle) async -> AIFullTextOutcome {
		lock.withLock {
			storedFetchCount += 1
		}
		return outcome
	}
}

private final class RewriteRecordingClient: AIClient, @unchecked Sendable {

	private let lock = NSLock()
	private var storedCallCount = 0
	private var storedLastUserMessage: String?

	var callCount: Int {
		lock.withLock {
			storedCallCount
		}
	}

	var lastUserMessage: String? {
		lock.withLock {
			storedLastUserMessage
		}
	}

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		lock.withLock {
			storedCallCount += 1
			storedLastUserMessage = messages.last(where: { $0.role == "user" })?.content
		}
		return Array(repeating: String(repeating: "改", count: 100), count: 3).joined(separator: "\n\n")
	}
}

/// Returns too little Chinese for `AIRewriteQualityValidator`, so the engine
/// stores the output but the service rejects it.
private final class ShortRewriteClient: AIClient, @unchecked Sendable {

	private let lock = NSLock()
	private var storedCallCount = 0

	var callCount: Int {
		lock.withLock {
			storedCallCount
		}
	}

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		lock.withLock {
			storedCallCount += 1
		}
		return "太短"
	}
}

private final class CountingClient: AIClient, @unchecked Sendable {

	private let lock = NSLock()
	private var count = 0

	var callCount: Int {
		lock.withLock {
			count
		}
	}

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		lock.withLock {
			count += 1
		}
		throw AIClientError.invalidResponse
	}
}

private final class FailureCounter: @unchecked Sendable {

	private let lock = NSLock()
	private var count = 0

	var value: Int {
		lock.lock()
		defer {
			lock.unlock()
		}
		return count
	}

	func increment() {
		lock.lock()
		count += 1
		lock.unlock()
	}
}

/// Holds the first model call open until the test releases it, so stopping the
/// executor can be timed while a job is being executed.
private final class BlockingClient: AIClient, @unchecked Sendable {

	private let articleID: String
	private let lock = NSLock()
	private var started = false
	private var released = false
	private var startWaiter: CheckedContinuation<Void, Never>?
	private var releaseWaiter: CheckedContinuation<Void, Never>?

	init(articleID: String) {
		self.articleID = articleID
	}

	func waitUntilStarted() async {
		await withCheckedContinuation { continuation in
			lock.lock()
			if started {
				lock.unlock()
				continuation.resume()
				return
			}
			startWaiter = continuation
			lock.unlock()
		}
	}

	func release() {
		lock.lock()
		released = true
		let waiter = releaseWaiter
		releaseWaiter = nil
		lock.unlock()
		waiter?.resume()
	}

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		await withCheckedContinuation { continuation in
			lock.lock()
			started = true
			let waiter = startWaiter
			startWaiter = nil
			if released {
				lock.unlock()
				continuation.resume()
			} else {
				releaseWaiter = continuation
				lock.unlock()
			}
			waiter?.resume()
		}
		return #"{"translations":[{"id":"\#(articleID)","titleZh":"中文标题"}]}"#
	}
}

private final class TitleClient: AIClient, Sendable {

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		let content = messages.last?.content ?? ""
		let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
		let items = object?["items"] as? [[String: Any]] ?? []
		let translations = items.compactMap { item -> [String: Any]? in
			guard let id = item["id"] as? String else {
				return nil
			}
			return ["id": id, "titleZh": "中文标题"]
		}
		return String(decoding: try JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)
	}
}

@MainActor
private final class EmptyResolver: AIArticleResolving {

	func article(for articleID: String) async -> AIArticle? {
		nil
	}
}

@MainActor
private final class FixedResolver: AIArticleResolving {

	private let fixedArticle: AIArticle

	init(article: AIArticle) {
		self.fixedArticle = article
	}

	func article(for articleID: String) async -> AIArticle? {
		articleID == fixedArticle.id ? fixedArticle : nil
	}
}
