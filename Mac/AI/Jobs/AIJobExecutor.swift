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
	let model: String
}

/// Everything the catch-up scan needs from the live account graph. Injected so
/// tests can run the real executor without touching `AccountManager`.
struct AICatchUpSource: Sendable {
	var articles: [AIArticle]
	var rewriteExcludedArticleIDs: Set<String>
	var translationExcludedArticleIDs: Set<String>

	init(articles: [AIArticle] = [], rewriteExcludedArticleIDs: Set<String> = [], translationExcludedArticleIDs: Set<String> = []) {
		self.articles = articles
		self.rewriteExcludedArticleIDs = rewriteExcludedArticleIDs
		self.translationExcludedArticleIDs = translationExcludedArticleIDs
	}
}

/// What happened when the translation pane asked for a body translation.
enum BodyTranslationEnqueueResult {
	case enqueued
	case alreadyInFlight
	case notNeeded
	case failed
}

/// How a rewrite entered the queue. Used only for the task log.
enum AIJobOrigin: Sendable, Equatable {
	case auto
	case manual
	case catchUp

	var trigger: AITaskLogTrigger {
		switch self {
		case .auto:
			return .auto
		case .manual:
			return .manual
		case .catchUp:
			return .catchUp
		}
	}
}

/// Keeps the origin of jobs that were queued by this executor. Jobs inserted
/// directly into the store have no entry and are logged as `unknown`.
struct AIJobOriginRegistry {

	private var origins: [String: AIJobOrigin] = [:]

	mutating func register(jobID: String, origin: AIJobOrigin) {
		origins[jobID] = origin
	}

	mutating func remove(jobID: String) {
		origins.removeValue(forKey: jobID)
	}

	func origin(for jobID: String) -> AIJobOrigin? {
		origins[jobID]
	}
}

/// Why a rewrite did or did not enter the queue.
enum RewriteEnqueueResult: Equatable, Sendable {
	case enqueued
	case blocked(AITaskLogReason)
	case alreadyUpToDate
	case alreadyInFlight
	case failed
}

/// The title batch plus the values the task log needs from that call.
struct TitleBatchOutcome {
	let result: TitleTranslationResult
	let batchSize: Int
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
	private static let leaseRenewInterval: Duration = .seconds(60)
	/// Finished jobs stay in the database for this long so the task panel can
	/// still show recent results.
	private static let terminalJobRetention: TimeInterval = 30 * 24 * 60 * 60
	/// User-visible translation work gets its own lane so it never waits behind
	/// a long rewrite.
	private static let interactiveKinds: [AIJobKind] = [.bodyTranslation, .titleTranslation]
	private static let backgroundKinds: [AIJobKind] = [.rewrite]
	/// Rollback switch: false puts every kind back on a single lane.
	private static let backgroundLaneEnabled = true
	private static let didPruneRewriteBacklogKey = "AI.DidPruneRewriteBacklog"
	nonisolated private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AIJobs")

	private let store: AIStore
	private let queue: AIQueue
	private let resolver: AIArticleResolving
	private let fullTextFetcher: AIFullTextFetching
	private let services: @MainActor () -> AIJobServices
	private let isConfigured: @MainActor () -> Bool
	private let notificationCenter: NotificationCenter
	private let autoStart: Bool
	private let catchUpSourceProvider: @MainActor () async -> AICatchUpSource
	private let chineseAllowedFeedIDsProvider: @MainActor () -> Set<String>
	/// Acceptance-only switch. The environment variable is unset in normal use,
	/// so every automatic paid path keeps its regular behaviour.
	private let autoWorkDisabled: Bool
	private let taskLog: AITaskLogging

	private var interactiveLoopTask: Task<Void, Never>?
	private var backgroundLoopTask: Task<Void, Never>?
	private var catchUpTask: Task<Void, Never>?
	private var observerToken: NSObjectProtocol?
	private var feedRemovalObserverToken: NSObjectProtocol?
	private var isPaused = false
	private var didScheduleTerminalJobCleanup = false
	/// Title translations are claimed only by the interactive lane, so this map
	/// keeps a single writer. Moving title jobs to the background lane would let
	/// two lanes mutate it concurrently.
	private var pendingTitleArticles: [String: AIArticle] = [:]
	private var reservations = AIEnqueueReservations()
	private var originRegistry = AIJobOriginRegistry()

	private init() {
		let environment = AIEnvironment.shared
		self.store = environment.store
		self.queue = environment.queue
		self.resolver = AIArticleResolver()
		self.fullTextFetcher = AIFullTextFetcher()
		self.services = {
			let environment = AIEnvironment.shared
			return AIJobServices(
				translation: AITranslationService(store: environment.store, engine: environment.engine, config: environment.config),
				rewrite: AIRewriteService(store: environment.store, engine: environment.engine),
				model: environment.config.model
			)
		}
		self.isConfigured = {
			AIEnvironment.shared.hasAPIKey
		}
		self.notificationCenter = .default
		self.autoStart = true
		self.catchUpSourceProvider = Self.liveCatchUpSource
		self.chineseAllowedFeedIDsProvider = Self.liveChineseAllowedFeedIDs
		self.autoWorkDisabled = Self.environmentAutoWorkDisabled
		self.taskLog = AITaskLog.shared
	}

	init(
		store: AIStore,
		queue: AIQueue,
		resolver: AIArticleResolving,
		fullTextFetcher: AIFullTextFetching = AIFullTextFetcher(),
		services: @escaping @MainActor () -> AIJobServices,
		isConfigured: @escaping @MainActor () -> Bool = { true },
		notificationCenter: NotificationCenter = .default,
		autoStart: Bool = true,
		catchUpSourceProvider: (@MainActor () async -> AICatchUpSource)? = nil,
		chineseAllowedFeedIDsProvider: (@MainActor () -> Set<String>)? = nil,
		autoWorkDisabled: Bool? = nil,
		taskLog: AITaskLogging = AITaskLog.shared
	) {
		self.store = store
		self.queue = queue
		self.resolver = resolver
		self.fullTextFetcher = fullTextFetcher
		self.services = services
		self.isConfigured = isConfigured
		self.notificationCenter = notificationCenter
		self.autoStart = autoStart
		self.catchUpSourceProvider = catchUpSourceProvider ?? Self.liveCatchUpSource
		self.chineseAllowedFeedIDsProvider = chineseAllowedFeedIDsProvider ?? Self.liveChineseAllowedFeedIDs
		self.autoWorkDisabled = autoWorkDisabled ?? Self.environmentAutoWorkDisabled
		self.taskLog = taskLog
	}

	// MARK: - Lifecycle

	func start() {
		installObserverIfNeeded()
		scheduleTerminalJobCleanupIfNeeded()
		guard interactiveLoopTask == nil, backgroundLoopTask == nil else {
			return
		}
		pruneRewriteBacklogIfNeeded()
		if Self.backgroundLaneEnabled {
			interactiveLoopTask = Task { @MainActor [weak self] in
				await self?.runLoop(allowedKinds: Self.interactiveKinds)
			}
			backgroundLoopTask = Task { @MainActor [weak self] in
				await self?.runLoop(allowedKinds: Self.backgroundKinds)
			}
		} else {
			interactiveLoopTask = Task { @MainActor [weak self] in
				await self?.runLoop(allowedKinds: nil)
			}
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
		interactiveLoopTask?.cancel()
		interactiveLoopTask = nil
		backgroundLoopTask?.cancel()
		backgroundLoopTask = nil
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

	/// The acceptance gate also stops the translation pane from retrying its
	/// automatic enqueue, which would otherwise loop on a gated `.notNeeded`.
	var isAutoWorkDisabled: Bool {
		autoWorkDisabled
	}

	/// The lane's claim step, isolated so the acceptance gate can be tested
	/// without waiting on the polling loop. Both lanes enter through here, so the
	/// gate cannot be bypassed.
	func claimNextJob(allowedKinds: [AIJobKind]?) async throws -> AIJob? {
		guard !autoWorkDisabled else {
			return nil
		}
		return try await queue.runOnce(allowedKinds: allowedKinds)
	}

	/// Unfiltered claim kept for the existing tests. Callers that run a lane use
	/// the gated `allowedKinds` variant instead.
	func claimNextJob() async throws -> AIJob? {
		try await claimNextJob(allowedKinds: nil)
	}

	/// Runs a claimed job through the same path as the loop. Exposed for tests so
	/// the execution-time gates can be exercised directly.
	func runJob(_ job: AIJob) async {
		await execute(job)
	}

	// MARK: - Enqueueing

	/// Queues title translation for new or updated foreign articles and, when
	/// the default is on, a rewrite for eligible articles in any language. Body
	/// translation is not queued here: it runs only when the reader opens the
	/// translation tab. `AutoWorkPolicy` filters this automatic path only;
	/// manual entry points are never filtered. Chinese articles are skipped
	/// unless their feed has the language override set.
	func enqueueForNewArticles(_ articles: [AIArticle]) async {
		guard !autoWorkDisabled else {
			return
		}
		guard isConfigured() else {
			return
		}
		let now = Date()
		let chineseAllowedFeedIDs = currentChineseAllowedFeedIDs
		let usable = articles.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		// A job that already exists, including one waiting to retry, must not be
		// queued again by a later download notification.
		let activeRewriteIDs = (try? await store.activeJobArticleIDs(kinds: [.rewrite])) ?? []
		let activeTitleIDs = (try? await store.activeJobArticleIDs(kinds: [.titleTranslation])) ?? []
		let disabledTranslationFeedIDs = translationDisabledFeedIDs
		let translatable = usable.filter {
			AutoWorkPolicy.shouldTranslate($0, now: now, chineseAllowed: AIArticleLanguageGate.allows($0, chineseAllowedFeedIDs: chineseAllowedFeedIDs))
				&& !activeTitleIDs.contains($0.id)
				&& AIRewriteAdmission.allowsTranslation(feedID: $0.feedID, translationDisabledFeedIDs: disabledTranslationFeedIDs)
		}
		await enqueueTitleTranslations(for: translatable, origin: .auto)

		guard AppDefaults.aiAutoRewriteEnabled else {
			return
		}
		for article in usable where AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: AIArticleLanguageGate.allows(article, chineseAllowedFeedIDs: chineseAllowedFeedIDs)) && !activeRewriteIDs.contains(article.id) {
			_ = await enqueueRewrite(for: article, origin: .auto)
		}
	}

	/// Queues work that the download notification path missed, for example
	/// because no API key was configured when the articles arrived or a job
	/// exhausted its retries. Only articles from the last two days are
	/// inspected. Repeated scans are harmless because cached work is skipped.
	func catchUpMissedWork() async {
		guard !autoWorkDisabled else {
			return
		}
		guard isConfigured() else {
			return
		}
		let now = Date()
		let cutoff = now.addingTimeInterval(-AutoWorkPolicy.recencyWindow)
		let source = await catchUpSourceProvider()

		var articlesByID: [String: AIArticle] = [:]
		for aiArticle in source.articles {
			guard !aiArticle.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				continue
			}
			guard let publishedAt = aiArticle.publishedAt, publishedAt >= cutoff else {
				continue
			}
			articlesByID[aiArticle.id] = aiArticle
		}
		let rewriteExcludedArticleIDs = source.rewriteExcludedArticleIDs
		let translationExcludedArticleIDs = source.translationExcludedArticleIDs

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
			rewriteExcludedArticleIDs: rewriteExcludedArticleIDs,
			translationExcludedArticleIDs: translationExcludedArticleIDs,
			chineseAllowedFeedIDs: currentChineseAllowedFeedIDs,
			limit: Self.catchUpLimit
		)

		var enqueuedCount = 0
		var titleArticles: [AIArticle] = []
		let disabledTranslationFeedIDs = translationDisabledFeedIDs
		for articleID in plan.titleTranslationArticleIDs where !activeTitleIDs.contains(articleID) {
			guard let article = articlesByID[articleID] else {
				continue
			}
			guard AIRewriteAdmission.allowsTranslation(feedID: article.feedID, translationDisabledFeedIDs: disabledTranslationFeedIDs) else {
				continue
			}
			guard !reservations.contains(Self.key(kind: .titleTranslation, articleID: articleID)) else {
				continue
			}
			titleArticles.append(article)
		}
		enqueuedCount += titleArticles.count
		await enqueueTitleTranslations(for: titleArticles, origin: .catchUp)

		if AppDefaults.aiAutoRewriteEnabled {
			for articleID in plan.rewriteArticleIDs where !activeRewriteIDs.contains(articleID) {
				guard let article = articlesByID[articleID] else {
					continue
				}
				guard !reservations.contains(Self.key(kind: .rewrite, articleID: articleID)) else {
					continue
				}
				enqueuedCount += 1
				_ = await enqueueRewrite(for: article, origin: .catchUp)
			}
		}

		Self.logger.info("AI catch-up scanned \(articles.count, privacy: .public) articles, queued \(enqueuedCount, privacy: .public) jobs")
	}

	func enqueueTitleTranslations(for articles: [AIArticle], origin: AIJobOrigin = .manual) async {
		let disabledFeedIDs = translationDisabledFeedIDs
		let chineseAllowedFeedIDs = currentChineseAllowedFeedIDs
		var jobs: [AIJob] = []
		var jobsByArticleID: [String: AIArticle] = [:]
		for article in articles {
			guard !article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				continue
			}
			guard AIArticleLanguageGate.allows(article, chineseAllowedFeedIDs: chineseAllowedFeedIDs) else {
				await recordManualRejection(origin, kind: .translateTitles, article: article, reason: .chineseArticle)
				continue
			}
			guard AIRewriteAdmission.allowsTranslation(feedID: article.feedID, translationDisabledFeedIDs: disabledFeedIDs) else {
				await recordManualRejection(origin, kind: .translateTitles, article: article, reason: .feedTranslationDisabled)
				continue
			}
			let key = Self.key(kind: .titleTranslation, articleID: article.id)
			guard !reservations.contains(key) else {
				await recordManualRejection(origin, kind: .translateTitles, article: article, reason: .alreadyInFlight)
				continue
			}
			if let cached = try? await store.translation(for: article.id),
			   let titleZh = cached.titleZh,
			   !titleZh.isEmpty,
			   AIContentHash.matchesTitleHash(cached.contentHash, article: article) {
				continue
			}
			guard reservations.reserve(key) else {
				await recordManualRejection(origin, kind: .translateTitles, article: article, reason: .alreadyInFlight)
				continue
			}
			pendingTitleArticles[article.id] = article
			jobsByArticleID[article.id] = article
			jobs.append(AIJobFactory.job(articleID: article.id, kind: .titleTranslation))
		}
		await enqueue(jobs, origin: origin, articles: jobsByArticleID)
	}

	/// Queues the body translation for the pane that just opened. The reservation
	/// is taken before the first `await`, so two openings in the same turn cannot
	/// both decide the job is missing and queue it twice.
	@discardableResult
	func enqueueBodyTranslation(for article: AIArticle) async -> BodyTranslationEnqueueResult {
		guard !autoWorkDisabled else {
			await recordManualRejection(.manual, kind: .translate, article: article, reason: .autoWorkDisabled)
			return .notNeeded
		}
		guard AIArticleLanguageGate.allows(article, chineseAllowedFeedIDs: currentChineseAllowedFeedIDs) else {
			await recordManualRejection(.manual, kind: .translate, article: article, reason: .chineseArticle)
			return .notNeeded
		}
		guard AIRewriteAdmission.allowsTranslation(feedID: article.feedID, translationDisabledFeedIDs: translationDisabledFeedIDs) else {
			await recordManualRejection(.manual, kind: .translate, article: article, reason: .feedTranslationDisabled)
			return .notNeeded
		}
		guard article.hasBody else {
			await recordManualRejection(.manual, kind: .translate, article: article, reason: .emptyBody)
			return .notNeeded
		}
		let key = Self.key(kind: .bodyTranslation, articleID: article.id)
		guard reservations.reserve(key) else {
			await recordManualRejection(.manual, kind: .translate, article: article, reason: .alreadyInFlight)
			return .alreadyInFlight
		}
		return await enqueueBodyTranslationReserved(article: article, key: key)
	}

	@discardableResult
	func enqueueRewrite(for article: AIArticle, origin: AIJobOrigin = .manual) async -> RewriteEnqueueResult {
		guard AIArticleLanguageGate.allows(article, chineseAllowedFeedIDs: currentChineseAllowedFeedIDs) else {
			await recordManualRejection(origin, kind: .rewrite, article: article, reason: .chineseArticle)
			return .blocked(.chineseArticle)
		}
		guard AIRewriteAdmission.allowsRewrite(feedID: article.feedID, rewriteDisabledFeedIDs: rewriteDisabledFeedIDs) else {
			await recordManualRejection(origin, kind: .rewrite, article: article, reason: .feedRewriteDisabled)
			return .blocked(.feedRewriteDisabled)
		}
		guard article.hasBody else {
			await recordManualRejection(origin, kind: .rewrite, article: article, reason: .emptyBody)
			return .blocked(.emptyBody)
		}
		let key = Self.key(kind: .rewrite, articleID: article.id)
		guard reservations.reserve(key) else {
			await recordManualRejection(origin, kind: .rewrite, article: article, reason: .alreadyInFlight)
			return .alreadyInFlight
		}
		// A manual click always re-runs the rewrite: the executor still skips the
		// model call when the stored hash matches, but the job must reach it so
		// the pane can move off an outdated pipeline result.
		if origin != .manual,
		   let cached = try? await store.rewrite(for: article.id),
		   AIContentHash.isRewriteUpToDate(stored: cached.contentHash, article: article),
		   !cached.bodyMarkdown.isEmpty {
			reservations.release(key)
			return .alreadyUpToDate
		}
		let priority = origin == .manual ? 100 : AIJobFactory.priority(for: .rewrite)
		let queued = await enqueue([AIJobFactory.job(articleID: article.id, kind: .rewrite, priority: priority)], origin: origin, articles: [article.id: article])
		guard queued else {
			return .failed
		}
		return .enqueued
	}

	@discardableResult
	func enqueueBodyTranslation(articleID: String) async -> BodyTranslationEnqueueResult {
		guard let article = await resolver.article(for: articleID) else {
			await recordManualRejection(.manual, kind: .translate, article: nil, articleID: articleID, outcome: .failed, reason: .articleMissing, error: "找不到文章")
			return .notNeeded
		}
		return await enqueueBodyTranslation(for: article)
	}

	func enqueueTitleTranslation(articleID: String) async {
		guard let article = await resolver.article(for: articleID) else {
			await recordManualRejection(.manual, kind: .translateTitles, article: nil, articleID: articleID, outcome: .failed, reason: .articleMissing, error: "找不到文章")
			return
		}
		await enqueueTitleTranslations(for: [article], origin: .manual)
	}

	@discardableResult
	func enqueueRewrite(articleID: String) async -> RewriteEnqueueResult {
		guard let article = await resolver.article(for: articleID) else {
			await recordManualRejection(.manual, kind: .rewrite, article: nil, articleID: articleID, outcome: .failed, reason: .articleMissing, error: "找不到文章")
			return .failed
		}
		return await enqueueRewrite(for: article, origin: .manual)
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

	/// Drops terminal job rows past the retention window once per executor
	/// lifetime. The cleanup runs off the main actor and never blocks the job
	/// loops.
	func scheduleTerminalJobCleanupIfNeeded() {
		guard !didScheduleTerminalJobCleanup else {
			return
		}
		didScheduleTerminalJobCleanup = true
		let cutoff = Date().addingTimeInterval(-Self.terminalJobRetention)
		let store = self.store
		Task.detached(priority: .utility) {
			do {
				let deleted = try await store.deleteTerminalJobs(olderThan: cutoff)
				if deleted > 0 {
					Self.logger.info("Deleted \(deleted, privacy: .public) expired AI job rows")
				}
			} catch {
				Self.logger.error("Failed to delete expired AI jobs: \(String(describing: error), privacy: .public)")
			}
		}
	}

	func handleRemovedFeeds(articleIDs: Set<String>) async {
		do {
			try await store.deleteAIArtifacts(articleIDs: articleIDs)
		} catch {
			Self.logger.error("Failed to delete AI artifacts for removed feeds: \(String(describing: error), privacy: .public)")
		}
		reservations.removeAll { key in
			let parts = key.split(separator: ":", maxSplits: 1)
			guard parts.count == 2 else {
				return false
			}
			return articleIDs.contains(String(parts[1]))
		}
		for articleID in articleIDs {
			pendingTitleArticles.removeValue(forKey: articleID)
		}
	}

	func runLoop(allowedKinds: [AIJobKind]?) async {
		while !Task.isCancelled {
			if isPaused {
				try? await Task.sleep(for: Self.pausedPollInterval)
				continue
			}

			do {
				guard let job = try await claimNextJob(allowedKinds: allowedKinds) else {
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
		// Generations can outlive the initial five minute lease. Renew it while
		// this job runs so the other lane cannot reclaim it; the heartbeat is only
		// a hint and never changes the job's outcome.
		let heartbeat = Task { [store] in
			while !Task.isCancelled {
				do {
					try await Task.sleep(for: Self.leaseRenewInterval)
				} catch {
					return
				}
				guard !Task.isCancelled else {
					return
				}
				try? await store.renewLease(id: job.id, now: Date())
			}
		}
		defer {
			heartbeat.cancel()
			reservations.release(Self.key(kind: job.kind, articleID: job.articleID))
		}

		let startedAt = job.startedAt ?? Date()
		let jobServices = services()
		let model = jobServices.model
		let trigger = originRegistry.origin(for: job.id)?.trigger ?? .unknown

		guard isConfigured() else {
			let message = "未配置模型 API key"
			do {
				try await store.failJobPermanently(id: job.id, error: message)
				await recordTerminal(terminalEvent(
					job: job,
					article: nil,
					trigger: trigger,
					model: model,
					startedAt: startedAt,
					outcome: .failed,
					reason: .notConfigured,
					error: message
				))
			} catch {
				Self.logger.error("Failed to record unconfigured AI job: \(String(describing: error), privacy: .public)")
			}
			postFailure(articleID: job.articleID, error: message)
			return
		}

		guard let article = await resolver.article(for: job.articleID) else {
			let message = "找不到文章"
			do {
				try await store.failJobPermanently(id: job.id, error: message)
				await recordTerminal(terminalEvent(
					job: job,
					article: nil,
					trigger: trigger,
					model: model,
					startedAt: startedAt,
					outcome: .failed,
					reason: .articleMissing,
					error: message
				))
			} catch {
				Self.logger.error("Failed to record missing-article AI job: \(String(describing: error), privacy: .public)")
			}
			postFailure(articleID: job.articleID, error: message)
			return
		}

		// A Chinese article whose feed has no language override never reaches the
		// model, even when a job was persisted before the rule existed. The job
		// completes silently: it is not retried and no failure notification fires.
		guard AIArticleLanguageGate.allows(article, chineseAllowedFeedIDs: currentChineseAllowedFeedIDs) else {
			do {
				try await store.completeJob(id: job.id)
				await recordTerminal(terminalEvent(
					job: job,
					article: article,
					trigger: trigger,
					model: model,
					startedAt: startedAt,
					outcome: .skipped,
					reason: .chineseArticle
				))
			} catch {
				Self.logger.error("Failed to complete Chinese AI job: \(String(describing: error), privacy: .public)")
			}
			return
		}

		do {
			switch job.kind {
			case .titleTranslation:
				guard AIRewriteAdmission.allowsTranslation(feedID: article.feedID, translationDisabledFeedIDs: translationDisabledFeedIDs) else {
					try await store.completeJob(id: job.id)
					await recordTerminal(terminalEvent(
						job: job,
						article: article,
						trigger: trigger,
						model: model,
						startedAt: startedAt,
						outcome: .skipped,
						reason: .feedTranslationDisabled
					))
					break
				}
				let batch = try await translateTitles(article: article, service: jobServices.translation)
				let ownSucceeded = batch.result.translated.contains(article.id) || batch.result.cached.contains(article.id)
				guard ownSucceeded else {
					let message = "模型未返回该标题"
					let terminal = AIQueuePolicy.retryDelay(afterAttempt: job.attempts) == nil
					try await store.failJob(id: job.id, error: message, retryAt: nil)
					if terminal {
						postFailure(articleID: article.id, error: message)
						await recordTerminal(terminalEvent(
							job: job,
							article: article,
							trigger: trigger,
							model: model,
							startedAt: startedAt,
							outcome: .failed,
							error: message,
							batchSize: batch.batchSize
						))
					}
					return
				}
				try await store.completeJob(id: job.id)
				let stored = try? await store.translation(for: job.articleID)
				let outcome: AITaskLogOutcome = batch.result.cached.contains(article.id) ? .cached : .stored
				for articleID in batch.result.translated {
					postTranslationReady(articleID: articleID)
				}
				await recordTerminal(terminalEvent(
					job: job,
					article: article,
					trigger: trigger,
					model: model,
					startedAt: startedAt,
					outcome: outcome,
					outputCharacters: stored?.titleZh?.count,
					batchSize: batch.batchSize
				))
			case .bodyTranslation:
				guard AIRewriteAdmission.allowsTranslation(feedID: article.feedID, translationDisabledFeedIDs: translationDisabledFeedIDs) else {
					try await store.completeJob(id: job.id)
					await recordTerminal(terminalEvent(
						job: job,
						article: article,
						trigger: trigger,
						model: model,
						startedAt: startedAt,
						outcome: .skipped,
						reason: .feedTranslationDisabled
					))
					break
				}
				// A job persisted before the body check, or an article whose HTML
				// is blank, has nothing to translate.
				guard article.hasBody else {
					try await store.completeJob(id: job.id)
					await recordTerminal(terminalEvent(
						job: job,
						article: article,
						trigger: trigger,
						model: model,
						startedAt: startedAt,
						outcome: .skipped,
						reason: .emptyBody
					))
					break
				}
				let result = try await jobServices.translation.translateBody(article)
				try await store.completeJob(id: job.id)
				postTranslationReady(articleID: article.id)
				let outputCharacters = result.translation.blocks.reduce(0) { count, block in
					count + block.target.count
				}
				await recordTerminal(terminalEvent(
					job: job,
					article: article,
					trigger: trigger,
					model: model,
					startedAt: startedAt,
					outcome: result.wasCached ? .cached : .stored,
					outputCharacters: outputCharacters,
					blocks: result.translation.blocks.count
				))
			case .rewrite:
				// A rewrite claimed before the feed's switch was turned off may
				// still be running; one row is the accepted residual. The check
				// runs when the job starts so a newly toggled switch blocks it.
				guard AIRewriteAdmission.allowsRewrite(feedID: article.feedID, rewriteDisabledFeedIDs: rewriteDisabledFeedIDs) else {
					try await store.completeJob(id: job.id)
					await recordTerminal(terminalEvent(
						job: job,
						article: article,
						trigger: trigger,
						model: model,
						startedAt: startedAt,
						outcome: .skipped,
						reason: .feedRewriteDisabled
					))
					break
				}
				// A teaser with fewer than five alphanumeric characters cannot be
				// checked against any page. Manual rewrites skip the hasBody check
				// elsewhere, so the guard lives here for every rewrite path.
				if AIRewriteKindSelector.kind(for: article) == .article,
				   !AIFullTextFetcher.hasUsableFeedBody(article) {
					await deleteNonFullTextRewrite(articleID: article.id)
					let message = "原文过短，已跳过改写"
					try? await store.failJobPermanently(id: job.id, error: message)
					await recordTerminal(terminalEvent(
						job: job,
						article: article,
						trigger: trigger,
						model: model,
						startedAt: startedAt,
						outcome: .skipped,
						reason: .bodyTooShort
					))
					postFailure(articleID: article.id, error: message)
					return
				}
				var rewriteArticle = article
				var usedFullText = false
				if await fullTextFetcher.isLikelySummary(article) {
					switch await fullTextFetcher.enrichedArticle(for: article) {
					case .notApplicable:
						break
					case .enriched(let enriched):
						rewriteArticle = enriched
						usedFullText = true
					case .unavailable:
						// Fetching or validating a longer page failed, or the page
						// was no longer than the feed. The feed body is still a
						// usable source, so rewrite from it instead of skipping.
						break
					}
				}
				let result = try await jobServices.rewrite.rewrite(rewriteArticle, fingerprintArticle: article, fullText: usedFullText, force: usedFullText)
				try await store.completeJob(id: job.id)
				postRewriteReady(articleID: article.id)
				let stored = try? await store.rewrite(for: article.id)
				await recordTerminal(terminalEvent(
					job: job,
					article: article,
					trigger: trigger,
					model: model,
					startedAt: startedAt,
					outcome: result.generated ? .stored : .cached,
					inputCharacters: result.inputCharacters,
					outputCharacters: stored?.bodyMarkdown.count,
					fullText: usedFullText
				))
			}
		} catch {
			let message = AIJobErrorDescription.describe(error)
			let terminal = AIQueuePolicy.retryDelay(afterAttempt: job.attempts) == nil
			do {
				try await store.failJob(id: job.id, error: message, retryAt: nil)
			} catch {
				Self.logger.error("Failed to record AI job failure: \(String(describing: error), privacy: .public)")
				return
			}
			Self.logger.error("AI job \(job.kind.rawValue, privacy: .public) failed: \(message, privacy: .public)")
			guard terminal else {
				return
			}
			postFailure(articleID: article.id, error: message)
			var reason: AITaskLogReason?
			if case AIRewriteError.qualityRejected = error {
				reason = .qualityRejected
			}
			await recordTerminal(terminalEvent(
				job: job,
				article: article,
				trigger: trigger,
				model: model,
				startedAt: startedAt,
				outcome: .failed,
				reason: reason,
				error: message
			))
		}
	}

	/// Translates the claimed article together with a few buffered articles so
	/// the engine can batch them. The buffered jobs stay in the queue and
	/// complete immediately from cache when their turn comes. Buffered articles
	/// from feeds that turned translation off are dropped instead of translated.
	func translateTitles(article: AIArticle, service: AITranslationService) async throws -> TitleBatchOutcome {
		let disabledFeedIDs = translationDisabledFeedIDs
		pendingTitleArticles = pendingTitleArticles.filter { _, pending in
			AIRewriteAdmission.allowsTranslation(feedID: pending.feedID, translationDisabledFeedIDs: disabledFeedIDs)
		}
		let batch = AITitleBatchPolicy.batch(article: article, pending: pendingTitleArticles, translationDisabledFeedIDs: disabledFeedIDs, limit: Self.titleBatchSize)
		for item in batch {
			pendingTitleArticles.removeValue(forKey: item.id)
		}
		guard !batch.isEmpty else {
			return TitleBatchOutcome(result: TitleTranslationResult(), batchSize: 0)
		}
		let result = try await service.translateTitles(batch)
		return TitleBatchOutcome(result: result, batchSize: batch.count)
	}

	/// Hands jobs to the queue. Returns false when any job could not be queued so
	/// callers can report the failure instead of assuming the work is running.
	@discardableResult
	func enqueue(_ jobs: [AIJob], origin: AIJobOrigin, articles: [String: AIArticle] = [:]) async -> Bool {
		guard !jobs.isEmpty else {
			return true
		}
		if autoStart {
			start()
		}
		var allQueued = true
		for job in jobs {
			do {
				try await queue.enqueue(job)
				originRegistry.register(jobID: job.id, origin: origin)
			} catch {
				allQueued = false
				originRegistry.remove(jobID: job.id)
				let failedArticle = articles[job.articleID] ?? pendingTitleArticles[job.articleID]
				reservations.release(Self.key(kind: job.kind, articleID: job.articleID))
				pendingTitleArticles.removeValue(forKey: job.articleID)
				await taskLog.recordAttempt(AITaskAttemptEvent(
					kind: job.kind.taskLogKind,
					articleID: job.articleID,
					title: failedArticle?.title,
					url: failedArticle?.url,
					trigger: origin.trigger,
					outcome: .failed,
					reason: .enqueueFailed,
					error: "提交任务失败"
				))
			}
		}
		return allQueued
	}

	/// Runs the body translation after its reservation was taken. Every early
	/// exit releases the reservation so a later attempt can try again.
	func enqueueBodyTranslationReserved(article: AIArticle, key: String) async -> BodyTranslationEnqueueResult {
		do {
			let active = try await store.activeJobArticleIDs(kinds: [.bodyTranslation])
			if active.contains(article.id) {
				reservations.release(key)
				await recordManualRejection(.manual, kind: .translate, article: article, reason: .alreadyInFlight)
				return .alreadyInFlight
			}
			if let cached = try await store.translation(for: article.id),
			   !cached.blocks.isEmpty {
				// Body translations are never re-run automatically: once readable
				// blocks exist they stay, even when the article or pipeline changes.
				reservations.release(key)
				return .notNeeded
			}
		} catch {
			reservations.release(key)
			await recordManualRejection(.manual, kind: .translate, article: article, outcome: .failed, reason: .enqueueFailed, error: "提交任务失败")
			return .failed
		}
		let queued = await enqueue([AIJobFactory.job(articleID: article.id, kind: .bodyTranslation)], origin: .manual, articles: [article.id: article])
		guard queued else {
			reservations.release(key)
			return .failed
		}
		return .enqueued
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

	/// Removes a stored teaser-based rewrite when the feed body is too short to
	/// rewrite. A full-text rewrite (`ft:`) is left in place.
	func deleteNonFullTextRewrite(articleID: String) async {
		guard let stored = try? await store.rewrite(for: articleID),
		      !stored.contentHash.hasPrefix("ft:") else {
			return
		}
		try? await store.deleteRewrite(articleID: articleID)
		postRewriteRemoved(articleID: articleID)
	}

	func postRewriteRemoved(articleID: String) {
		notificationCenter.post(
			name: .aiRewriteRemoved,
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

	/// The acceptance-only gate. It is off unless the environment variable is
	/// explicitly set to 1, so product behaviour is unchanged by default.
	static var environmentAutoWorkDisabled: Bool {
		ProcessInfo.processInfo.environment["NNW_DISABLE_AI_AUTOWORK"] == "1"
	}

	/// Feeds whose user override lets Chinese articles keep automatic AI work.
	@MainActor
	static func liveChineseAllowedFeedIDs() -> Set<String> {
		var feedIDs = Set<String>()
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() where feed.aiLanguageOverride {
				feedIDs.insert(feed.feedID)
			}
		}
		return feedIDs
	}

	/// Resolved on every check, so the override takes effect without restarting
	/// the executor.
	var currentChineseAllowedFeedIDs: Set<String> {
		chineseAllowedFeedIDsProvider()
	}

	/// Production catch-up source. Tests replace this with a fixed value so the
	/// executor never reaches into the live account graph.
	@MainActor
	static func liveCatchUpSource() async -> AICatchUpSource {
		var articles: [AIArticle] = []
		var rewriteExcludedArticleIDs = Set<String>()
		var translationExcludedArticleIDs = Set<String>()
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() {
				let fetched = await feed.fetchArticlesAsync()
				for article in fetched {
					let aiArticle = AIArticle(article: article)
					articles.append(aiArticle)
					if !feed.aiRewriteEnabled {
						rewriteExcludedArticleIDs.insert(aiArticle.id)
					}
					if !feed.aiTranslationEnabled {
						translationExcludedArticleIDs.insert(aiArticle.id)
					}
				}
			}
		}
		return AICatchUpSource(
			articles: articles,
			rewriteExcludedArticleIDs: rewriteExcludedArticleIDs,
			translationExcludedArticleIDs: translationExcludedArticleIDs
		)
	}

	/// Resolved live on every check, so toggling a switch takes effect without
	/// restarting the executor.
	var rewriteDisabledFeedIDs: Set<String> {
		var feedIDs = Set<String>()
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() where !feed.aiRewriteEnabled {
				feedIDs.insert(feed.feedID)
			}
		}
		return feedIDs
	}

	/// Resolved live on every check, so toggling a switch takes effect without
	/// restarting the executor.
	var translationDisabledFeedIDs: Set<String> {
		var feedIDs = Set<String>()
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() where !feed.aiTranslationEnabled {
				feedIDs.insert(feed.feedID)
			}
		}
		return feedIDs
	}

	static func key(kind: AIJobKind, articleID: String) -> String {
		"\(kind.rawValue):\(articleID)"
	}

	func terminalEvent(
		job: AIJob,
		article: AIArticle?,
		trigger: AITaskLogTrigger,
		model: String,
		startedAt: Date,
		outcome: AITaskLogOutcome,
		reason: AITaskLogReason? = nil,
		error: String? = nil,
		inputCharacters: Int? = nil,
		outputCharacters: Int? = nil,
		blocks: Int? = nil,
		batchSize: Int? = nil,
		fullText: Bool? = nil
	) -> AITaskTerminalEvent {
		let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
		return AITaskTerminalEvent(
			jobID: job.id,
			kind: job.kind.taskLogKind,
			articleID: job.articleID,
			title: article?.title,
			url: article?.url,
			trigger: trigger,
			outcome: outcome,
			reason: reason,
			error: error,
			durationMilliseconds: duration,
			feedCharacters: article.map { AIFullTextFetcher.bodyCharacterCount(for: $0) },
			inputCharacters: inputCharacters,
			outputCharacters: outputCharacters,
			blocks: blocks,
			batchSize: batchSize,
			fullText: fullText,
			model: model,
			attempts: job.attempts
		)
	}

	func recordTerminal(_ event: AITaskTerminalEvent) async {
		await taskLog.recordTerminal(event)
		originRegistry.remove(jobID: event.jobID)
	}

	/// Rejections in the automatic scan are policy noise and are not logged.
	/// Only manual entry points produce an attempt record.
	func recordManualRejection(
		_ origin: AIJobOrigin,
		kind: AITaskLogKind,
		article: AIArticle?,
		articleID: String? = nil,
		outcome: AITaskLogOutcome = .skipped,
		reason: AITaskLogReason? = nil,
		error: String? = nil
	) async {
		guard origin == .manual else {
			return
		}
		let resolvedArticleID = article?.id ?? articleID ?? ""
		await taskLog.recordAttempt(AITaskAttemptEvent(
			kind: kind,
			articleID: resolvedArticleID,
			title: article?.title,
			url: article?.url,
			trigger: .manual,
			outcome: outcome,
			reason: reason,
			error: error
		))
	}
}
