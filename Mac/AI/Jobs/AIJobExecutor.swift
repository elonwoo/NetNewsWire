//
//  AIJobExecutor.swift
//  NetNewsWire
//

import Account
import AI
import Articles
import Foundation
import os
import RSCore

struct AIJobServices {
	let translation: AITranslationService
	let rewrite: AIRewriteService
}

/// Serial executor for persisted AI jobs.
///
/// Jobs live in the SQLite store, so quitting the app never loses work: the
/// loop claims one job at a time, runs it, and records success or failure.
/// Failures follow `AIQueuePolicy` and are retried with backoff.
@MainActor
final class AIJobExecutor {

	static let shared = AIJobExecutor()

	private static let titleBatchSize = 20
	private static let idlePollInterval: Duration = .seconds(2)
	private static let pausedPollInterval: Duration = .seconds(1)
	private static let catchUpDelay: Duration = .seconds(5)
	private static let catchUpLimit = 200
	private static let didPruneRewriteBacklogKey = "AI.DidPruneRewriteBacklog"
	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AIJobs")

	private let store: AIStore
	private let queue: AIQueue
	private let resolver: AIArticleResolving
	private let services: @MainActor () -> AIJobServices
	private let isConfigured: @MainActor () -> Bool
	private let notificationCenter: NotificationCenter

	private var loopTask: Task<Void, Never>?
	private var catchUpTask: Task<Void, Never>?
	private var observerToken: NSObjectProtocol?
	private var feedRemovalObserverToken: NSObjectProtocol?
	private var isPaused = false
	private var pendingTitleArticles: [String: AIArticle] = [:]
	private var enqueuedKeys: Set<String> = []

	private init() {
		let environment = AIEnvironment.shared
		self.store = environment.store
		self.queue = environment.queue
		self.resolver = AIArticleResolver()
		self.services = {
			let environment = AIEnvironment.shared
			return AIJobServices(
				translation: AITranslationService(store: environment.store, engine: environment.engine, config: environment.config),
				rewrite: AIRewriteService(store: environment.store, engine: environment.engine)
			)
		}
		self.isConfigured = {
			AIEnvironment.shared.hasAPIKey
		}
		self.notificationCenter = .default
	}

	init(
		store: AIStore,
		queue: AIQueue,
		resolver: AIArticleResolving,
		services: @escaping @MainActor () -> AIJobServices,
		isConfigured: @escaping @MainActor () -> Bool = { true },
		notificationCenter: NotificationCenter = .default
	) {
		self.store = store
		self.queue = queue
		self.resolver = resolver
		self.services = services
		self.isConfigured = isConfigured
		self.notificationCenter = notificationCenter
	}

	// MARK: - Lifecycle

	func start() {
		installObserverIfNeeded()
		guard loopTask == nil else {
			return
		}
		pruneRewriteBacklogIfNeeded()
		loopTask = Task { @MainActor [weak self] in
			await self?.runLoop()
		}
		catchUpTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: Self.catchUpDelay)
			} catch {
				return
			}
			await self?.catchUpMissedWork()
		}
	}

	func stop() {
		loopTask?.cancel()
		loopTask = nil
		catchUpTask?.cancel()
		catchUpTask = nil
		if let observerToken {
			notificationCenter.removeObserver(observerToken)
			self.observerToken = nil
		}
		if let feedRemovalObserverToken {
			notificationCenter.removeObserver(feedRemovalObserverToken)
			self.feedRemovalObserverToken = nil
		}
	}

	func pause() {
		isPaused = true
		Task { [queue] in
			await queue.pause()
		}
	}

	func resume() {
		isPaused = false
		Task { [queue] in
			await queue.resume()
		}
		start()
	}

	// MARK: - Enqueueing

	/// Queues title translation for new or updated foreign articles and, when
	/// the default is on, a rewrite for eligible articles in any language. Body
	/// translation is not queued here: it runs only when the reader opens the
	/// translation tab. `AutoWorkPolicy` filters this automatic path only;
	/// manual entry points are never filtered.
	func enqueueForNewArticles(_ articles: [AIArticle]) async {
		guard isConfigured() else {
			return
		}
		let now = Date()
		let usable = articles.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		let translatable = usable.filter { AutoWorkPolicy.shouldTranslate($0, now: now) }
		await enqueueTitleTranslations(for: translatable)

		guard AppDefaults.aiAutoRewriteEnabled else {
			return
		}
		for article in usable where AutoWorkPolicy.shouldRewrite(article, now: now) {
			await enqueueRewrite(for: article)
		}
	}

	/// Queues work that the download notification path missed, for example
	/// because no API key was configured when the articles arrived or a job
	/// exhausted its retries. Only articles from the last seven days are
	/// inspected. Repeated scans are harmless because cached work is skipped.
	func catchUpMissedWork() async {
		guard isConfigured() else {
			return
		}
		let now = Date()
		let cutoff = now.addingTimeInterval(-AutoWorkPolicy.recencyWindow)

		var articlesByID: [String: AIArticle] = [:]
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() {
				let fetched = await feed.fetchArticlesAsync()
				for article in fetched {
					let aiArticle = AIArticle(article: article)
					guard !aiArticle.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
						continue
					}
					guard let publishedAt = aiArticle.publishedAt, publishedAt >= cutoff else {
						continue
					}
					articlesByID[aiArticle.id] = aiArticle
				}
			}
		}

		// Dedupe per kind: a pending title translation must not stop the same
		// article from getting its rewrite queued.
		let activeRewriteIDs = (try? await store.activeJobArticleIDs(kinds: [.rewrite])) ?? []
		let activeTitleIDs = (try? await store.activeJobArticleIDs(kinds: [.titleTranslation])) ?? []

		let articles = articlesByID.values
			.sorted {
				($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
			}

		var cachedRewrites: [String: String] = [:]
		var cachedTitleHashes: [String: String] = [:]
		for article in articles {
			if let cached = try? await store.rewrite(for: article.id), !cached.bodyMarkdown.isEmpty {
				cachedRewrites[article.id] = cached.contentHash
			}
			if let cached = try? await store.translation(for: article.id),
			   let titleZh = cached.titleZh,
			   !titleZh.isEmpty {
				cachedTitleHashes[article.id] = cached.contentHash
			}
		}

		let plan = AICatchUpPlanner.plan(
			articles: articles,
			now: now,
			cachedRewrites: cachedRewrites,
			cachedTitleHashes: cachedTitleHashes,
			limit: Self.catchUpLimit
		)

		var enqueuedCount = 0
		var titleArticles: [AIArticle] = []
		for articleID in plan.titleTranslationArticleIDs where !activeTitleIDs.contains(articleID) {
			guard let article = articlesByID[articleID] else {
				continue
			}
			guard !enqueuedKeys.contains(Self.key(kind: .titleTranslation, articleID: articleID)) else {
				continue
			}
			titleArticles.append(article)
		}
		enqueuedCount += titleArticles.count
		await enqueueTitleTranslations(for: titleArticles)

		if AppDefaults.aiAutoRewriteEnabled {
			for articleID in plan.rewriteArticleIDs where !activeRewriteIDs.contains(articleID) {
				guard let article = articlesByID[articleID] else {
					continue
				}
				guard !enqueuedKeys.contains(Self.key(kind: .rewrite, articleID: articleID)) else {
					continue
				}
				enqueuedCount += 1
				await enqueueRewrite(for: article)
			}
		}

		Self.logger.info("AI catch-up scanned \(articles.count, privacy: .public) articles, queued \(enqueuedCount, privacy: .public) jobs")
	}

	func enqueueTitleTranslations(for articles: [AIArticle]) async {
		var jobs: [AIJob] = []
		for article in articles {
			guard !article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				continue
			}
			let key = Self.key(kind: .titleTranslation, articleID: article.id)
			guard !enqueuedKeys.contains(key) else {
				continue
			}
			if let cached = try? await store.translation(for: article.id),
			   let titleZh = cached.titleZh,
			   !titleZh.isEmpty,
			   AIContentHash.matchesTitleHash(cached.contentHash, article: article) {
				continue
			}
			enqueuedKeys.insert(key)
			pendingTitleArticles[article.id] = article
			jobs.append(AIJobFactory.job(articleID: article.id, kind: .titleTranslation))
		}
		await enqueue(jobs)
	}

	func enqueueBodyTranslation(for article: AIArticle) async {
		guard Self.hasBody(article) else {
			return
		}
		let key = Self.key(kind: .bodyTranslation, articleID: article.id)
		guard !enqueuedKeys.contains(key) else {
			return
		}
		if let cached = try? await store.translation(for: article.id),
		   cached.contentHash == AIContentHash.body(for: article),
		   !cached.blocks.isEmpty {
			return
		}
		enqueuedKeys.insert(key)
		await enqueue([AIJobFactory.job(articleID: article.id, kind: .bodyTranslation)])
	}

	func enqueueRewrite(for article: AIArticle) async {
		guard Self.hasBody(article) else {
			return
		}
		let key = Self.key(kind: .rewrite, articleID: article.id)
		guard !enqueuedKeys.contains(key) else {
			return
		}
		if let cached = try? await store.rewrite(for: article.id),
		   cached.contentHash == AIContentHash.titleOrRewrite(for: article),
		   !cached.bodyMarkdown.isEmpty {
			return
		}
		enqueuedKeys.insert(key)
		await enqueue([AIJobFactory.job(articleID: article.id, kind: .rewrite)])
	}

	func enqueueBodyTranslation(articleID: String) async {
		guard let article = await resolver.article(for: articleID) else {
			return
		}
		await enqueueBodyTranslation(for: article)
	}

	func enqueueTitleTranslation(articleID: String) async {
		guard let article = await resolver.article(for: articleID) else {
			return
		}
		await enqueueTitleTranslations(for: [article])
	}

	func enqueueRewrite(articleID: String) async {
		guard let article = await resolver.article(for: articleID) else {
			return
		}
		await enqueueRewrite(for: article)
	}
}

// MARK: - Loop

private extension AIJobExecutor {

	/// Rewrites queued before `AutoWorkPolicy` existed were never filtered, so
	/// the backlog is cleared once. Runs off the caller's stack.
	func pruneRewriteBacklogIfNeeded() {
		guard !UserDefaults.standard.bool(forKey: Self.didPruneRewriteBacklogKey) else {
			return
		}
		Task { @MainActor [store] in
			do {
				try await store.deleteJobs(kinds: [.rewrite], statuses: [.pending, .retry, .running])
				UserDefaults.standard.set(true, forKey: Self.didPruneRewriteBacklogKey)
			} catch {
				Self.logger.error("Failed to prune rewrite backlog: \(String(describing: error), privacy: .public)")
			}
		}
	}

	func handleRemovedFeeds(articleIDs: Set<String>) async {
		do {
			try await store.deleteAIArtifacts(articleIDs: articleIDs)
		} catch {
			Self.logger.error("Failed to delete AI artifacts for removed feeds: \(String(describing: error), privacy: .public)")
		}
		enqueuedKeys = Set(enqueuedKeys.filter { key in
			let parts = key.split(separator: ":", maxSplits: 1)
			guard parts.count == 2 else {
				return true
			}
			return !articleIDs.contains(String(parts[1]))
		})
		for articleID in articleIDs {
			pendingTitleArticles.removeValue(forKey: articleID)
		}
	}

	func runLoop() async {
		while !Task.isCancelled {
			if isPaused {
				try? await Task.sleep(for: Self.pausedPollInterval)
				continue
			}

			do {
				guard let job = try await queue.runOnce() else {
					try? await Task.sleep(for: Self.idlePollInterval)
					continue
				}
				await execute(job)
			} catch {
				Self.logger.error("AI job loop failed: \(String(describing: error), privacy: .public)")
				try? await Task.sleep(for: Self.idlePollInterval)
			}
		}
	}

	func execute(_ job: AIJob) async {
		defer {
			enqueuedKeys.remove(Self.key(kind: job.kind, articleID: job.articleID))
		}

		guard isConfigured() else {
			let message = "未配置模型 API key"
			try? await store.failJobPermanently(id: job.id, error: message)
			postFailure(articleID: job.articleID, error: message)
			return
		}

		guard let article = await resolver.article(for: job.articleID) else {
			let message = "找不到文章"
			try? await store.failJobPermanently(id: job.id, error: message)
			postFailure(articleID: job.articleID, error: message)
			return
		}

		let jobServices = services()
		do {
			switch job.kind {
			case .titleTranslation:
				let generated = try await translateTitles(article: article, service: jobServices.translation)
				try await store.completeJob(id: job.id)
				for articleID in generated {
					postTranslationReady(articleID: articleID)
				}
			case .bodyTranslation:
				_ = try await jobServices.translation.translateBody(article)
				try await store.completeJob(id: job.id)
				postTranslationReady(articleID: article.id)
			case .rewrite:
				_ = try await jobServices.rewrite.rewrite(article)
				try await store.completeJob(id: job.id)
				postRewriteReady(articleID: article.id)
			}
		} catch {
			let message = AIJobErrorDescription.describe(error)
			let terminal = AIQueuePolicy.retryDelay(afterAttempt: job.attempts) == nil
			try? await store.failJob(id: job.id, error: message, retryAt: nil)
			Self.logger.error("AI job \(job.kind.rawValue, privacy: .public) failed: \(message, privacy: .public)")
			if terminal {
				postFailure(articleID: article.id, error: message)
			}
		}
	}

	/// Translates the claimed article together with a few buffered articles so
	/// the engine can batch them. The buffered jobs stay in the queue and
	/// complete immediately from cache when their turn comes.
	func translateTitles(article: AIArticle, service: AITranslationService) async throws -> Set<String> {
		var batch = [article]
		for (articleID, pending) in pendingTitleArticles where articleID != article.id && batch.count < Self.titleBatchSize {
			batch.append(pending)
		}

		let generated = try await service.translateTitles(batch)
		for item in batch {
			pendingTitleArticles.removeValue(forKey: item.id)
		}
		return generated
	}

	func enqueue(_ jobs: [AIJob]) async {
		guard !jobs.isEmpty else {
			return
		}
		start()
		for job in jobs {
			do {
				try await queue.enqueue(job)
			} catch {
				enqueuedKeys.remove(Self.key(kind: job.kind, articleID: job.articleID))
				pendingTitleArticles.removeValue(forKey: job.articleID)
			}
		}
	}
}

// MARK: - Notifications

private extension AIJobExecutor {

	func installObserverIfNeeded() {
		if observerToken == nil {
			observerToken = notificationCenter.addObserver(forName: .AccountDidDownloadArticles, object: nil, queue: .main) { [weak self] notification in
				guard let self else {
					return
				}
				var articles: [Article] = []
				if let newArticles = notification.userInfo?[Account.UserInfoKey.newArticles] as? Set<Article> {
					articles.append(contentsOf: newArticles)
				}
				if let updatedArticles = notification.userInfo?[Account.UserInfoKey.updatedArticles] as? Set<Article> {
					articles.append(contentsOf: updatedArticles)
				}
				guard !articles.isEmpty else {
					return
				}
				let aiArticles = articles.map { AIArticle(article: $0) }
				Task { @MainActor [weak self] in
					await self?.enqueueForNewArticles(aiArticles)
				}
			}
		}

		if feedRemovalObserverToken == nil {
			feedRemovalObserverToken = notificationCenter.addObserver(forName: .AccountDidRemoveFeeds, object: nil, queue: .main) { [weak self] notification in
				guard let self,
				      let articleIDs = notification.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>,
				      !articleIDs.isEmpty else {
					return
				}
				Task { @MainActor [weak self] in
					await self?.handleRemovedFeeds(articleIDs: articleIDs)
				}
			}
		}
	}

	func postTranslationReady(articleID: String) {
		notificationCenter.post(
			name: .aiTranslationReady,
			object: nil,
			userInfo: [AIUserInfoKey.articleID: articleID]
		)
	}

	func postRewriteReady(articleID: String) {
		notificationCenter.post(
			name: .aiRewriteReady,
			object: nil,
			userInfo: [AIUserInfoKey.articleID: articleID]
		)
	}

	func postFailure(articleID: String, error: String) {
		notificationCenter.post(
			name: .aiJobFailed,
			object: nil,
			userInfo: [
				AIUserInfoKey.articleID: articleID,
				AIUserInfoKey.error: error
			]
		)
	}
}

// MARK: - Helpers

private extension AIJobExecutor {

	static func key(kind: AIJobKind, articleID: String) -> String {
		"\(kind.rawValue):\(articleID)"
	}

	static func hasBody(_ article: AIArticle) -> Bool {
		if let text = article.contentText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		if let html = article.contentHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		return false
	}
}
