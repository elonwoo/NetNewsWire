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
		await executor.enqueueRewrite(for: article)
		#expect(try await store.activeJobArticleIDs(kinds: [.rewrite]).isEmpty)

		try await store.saveRewrite(rewrite(article: article, hash: AIContentHash.rewrite(for: article)))
		await executor.enqueueRewrite(for: article)
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

	func chineseArticle(id: String, publishedAt: Date? = nil, feedID: String = "zh-feed") -> AIArticle {
		AIArticle(
			id: id,
			title: "中文标题",
			contentText: String(repeating: "中", count: 2500),
			feedID: feedID,
			publishedAt: publishedAt
		)
	}

	func rewrite(article: AIArticle, hash: String) -> AI.Rewrite {
		AI.Rewrite(
			articleID: article.id,
			title: article.title,
			bodyMarkdown: "已有改写",
			model: "old-model",
			contentHash: hash,
			createdAt: Date(),
			updatedAt: Date()
		)
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
		notificationCenter: NotificationCenter = NotificationCenter()
	) -> AIJobExecutor {
		let engine = AIEngine(store: store, client: client, config: config)
		let store: SQLiteAIStore = self.store
		let config = self.config
		return AIJobExecutor(
			store: store,
			queue: queue,
			resolver: resolver,
			services: {
				AIJobServices(
					translation: AITranslationService(store: store, engine: engine, config: config),
					rewrite: AIRewriteService(store: store, engine: engine)
				)
			},
			isConfigured: { true },
			notificationCenter: notificationCenter,
			autoStart: false,
			catchUpSourceProvider: { source },
			chineseAllowedFeedIDsProvider: { chineseAllowedFeedIDs },
			autoWorkDisabled: autoWorkDisabled
		)
	}
}

private final class NoCallClient: AIClient, Sendable {

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		throw AIClientError.invalidResponse
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
