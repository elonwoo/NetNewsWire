//
//  AIJobStatusModel.swift
//  NetNewsWire
//

import AI
import Articles
import Foundation

/// What the right-pane task panel is looking at. The panel only supports the
/// five scopes from the design: a feed, a folder, Today, All Unread and Starred.
enum AIJobScopeKind: Equatable, Sendable {
	case feed
	case folder
	case today
	case allUnread
	case starred
}

struct AIJobScope: Equatable, Sendable {
	let kind: AIJobScopeKind
	let name: String
	/// Set for feed and folder scopes; empty for smart feeds.
	let feedIDs: Set<String>
	/// Number of feeds in a folder scope, used by the subtitle.
	let feedCount: Int

	init(kind: AIJobScopeKind, name: String, feedIDs: Set<String> = [], feedCount: Int = 0) {
		self.kind = kind
		self.name = name
		self.feedIDs = feedIDs
		self.feedCount = feedCount
	}

	/// The article metadata the model needs. Kept separate from `Article` so the
	/// model stays pure and testable.
	func contains(_ article: AIJobArticleInfo, now: Date) -> Bool {
		switch kind {
		case .feed, .folder:
			return feedIDs.contains(article.feedID)
		case .today:
			// Today is a rolling 24 hours. An article without a published date
			// falls back to its arrival date.
			let date = article.datePublished ?? article.dateArrived
			return date >= now.addingTimeInterval(-24 * 60 * 60)
		case .allUnread:
			return !article.read
		case .starred:
			return article.starred
		}
	}
}

struct AIJobArticleInfo: Equatable, Sendable {
	let articleID: String
	let title: String
	let feedID: String
	let feedName: String?
	let datePublished: Date?
	let dateArrived: Date
	let read: Bool
	let starred: Bool

	@MainActor
	init(article: Article) {
		self.articleID = article.articleID
		self.title = article.title ?? ""
		self.feedID = article.feedID
		self.feedName = article.feed?.nameForDisplay
		self.datePublished = article.datePublished
		self.dateArrived = article.status.dateArrived
		self.read = article.status.read
		self.starred = article.status.starred
	}

	init(articleID: String, title: String, feedID: String, feedName: String? = nil, datePublished: Date?, dateArrived: Date, read: Bool = false, starred: Bool = false) {
		self.articleID = articleID
		self.title = title
		self.feedID = feedID
		self.feedName = feedName
		self.datePublished = datePublished
		self.dateArrived = dateArrived
		self.read = read
		self.starred = starred
	}
}

/// Context handed from the window to the panel. The timeline articles are the
/// visible list: every count, the header and the coverage table use this one
/// set. Feed names are resolved before they reach the model so the coverage
/// builder never touches `Article.feed`.
struct AIJobPanelContext: Equatable, Sendable {
	let scope: AIJobScope
	let articles: [AIJobArticleInfo]
	let feedDisplayNames: [String: String]
	/// Whether the timeline currently hides read articles. The panel reports
	/// only what the list shows, so read articles drop out of every count.
	let unreadOnly: Bool

	var timelineArticleIDs: Set<String> {
		Set(articles.map(\.articleID))
	}

	var timelineArticleCount: Int {
		articles.count
	}
}

struct AIJobRequeueRequest: Hashable, Sendable {
	let articleID: String
	let kind: AIJobKind
}

/// The one-line state colours. Failures and retries deliberately stay out of
/// the sentence; they only appear in the four tiles and the attention zone.
enum AIJobStatusTone: Equatable, Sendable {
	case red
	case orange
	case green
	case yellow
	case gray
}

enum AIJobTileTone: Equatable, Sendable {
	case accent
	case neutral
	case retry
	case danger
}

struct AIJobTile: Equatable, Sendable {
	let title: String
	let count: Int
	let tone: AIJobTileTone
}

struct AIJobHeadline: Equatable, Sendable {
	let text: String
	let tone: AIJobStatusTone
}

// MARK: - Coverage

struct AIJobCoverageRow: Equatable, Sendable {
	let feedID: String
	let feedName: String
	let total: Int
	let translated: Int
	let rewritten: Int
	let original: Int

	var translatedOnly: Int {
		total - rewritten - original
	}
}

struct AIJobCoverage: Equatable, Sendable {
	let rows: [AIJobCoverageRow]
	let total: Int
	let translated: Int
	let rewritten: Int
	let translatedOnly: Int
	let original: Int

	var feedCount: Int {
		rows.count
	}
}

/// Pure per-feed coverage. The caller resolves feed names and supplies the two
/// completed sets; the builder never reads an `Article` or the store.
enum AIJobCoverageBuilder {

	static func feedDisplayName(feedName: String?, urlHost: String?, feedID: String) -> String {
		if let feedName, !feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return feedName
		}
		if let urlHost, !urlHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return urlHost
		}
		return feedID
	}

	static func build(
		articles: [AIJobArticleInfo],
		unreadOnly: Bool,
		feedDisplayNames: [String: String],
		translatedArticleIDs: Set<String>,
		rewrittenArticleIDs: Set<String>
	) -> AIJobCoverage {
		var seen: Set<String> = []
		let visible = articles.filter { article in
			guard !unreadOnly || !article.read else {
				return false
			}
			return seen.insert(article.articleID).inserted
		}

		var grouped: [String: [AIJobArticleInfo]] = [:]
		for article in visible {
			grouped[article.feedID, default: []].append(article)
		}

		let rows = grouped.map { feedID, feedArticles -> AIJobCoverageRow in
			let ids = Set(feedArticles.map(\.articleID))
			let translatedCount = ids.intersection(translatedArticleIDs).count
			let rewrittenCount = ids.intersection(rewrittenArticleIDs).count
			let originalCount = feedArticles.count - ids.intersection(translatedArticleIDs.union(rewrittenArticleIDs)).count
			let name = feedDisplayNames[feedID] ?? feedID
			return AIJobCoverageRow(
				feedID: feedID,
				feedName: name,
				total: feedArticles.count,
				translated: translatedCount,
				rewritten: rewrittenCount,
				original: originalCount
			)
		}.sorted { lhs, rhs in
			if lhs.total != rhs.total {
				return lhs.total > rhs.total
			}
			if lhs.feedName != rhs.feedName {
				return lhs.feedName < rhs.feedName
			}
			return lhs.feedID < rhs.feedID
		}

		let translatedCount = visible.filter { translatedArticleIDs.contains($0.articleID) }.count
		let rewrittenCount = visible.filter { rewrittenArticleIDs.contains($0.articleID) }.count
		let originalCount = visible.filter {
			!translatedArticleIDs.contains($0.articleID) && !rewrittenArticleIDs.contains($0.articleID)
		}.count
		return AIJobCoverage(
			rows: rows,
			total: visible.count,
			translated: translatedCount,
			rewritten: rewrittenCount,
			translatedOnly: rows.reduce(0) { $0 + $1.translatedOnly },
			original: originalCount
		)
	}
}

// MARK: - Attention

struct AIJobFailureGroupKey: Hashable, Sendable {
	let kind: AIJobKind
	let reason: String
}

struct AIJobFailureFeedCount: Equatable, Sendable {
	let feedName: String
	let count: Int
}

struct AIJobFailureGroup: Equatable, Sendable {
	let key: AIJobFailureGroupKey
	let kind: AIJobKind
	let reason: String
	let count: Int
	let perFeedCounts: [AIJobFailureFeedCount]
	let retryableJobs: [AIJobRequeueRequest]
	let isExpanded: Bool
	let isRetrying: Bool
	let retryNotice: String?

	var title: String {
		"\(count) 项\(AIJobStatusModel.kindLabel(kind))失败"
	}

	var involvedFeedsText: String {
		let parts = perFeedCounts.map { "\($0.feedName) \($0.count) 项" }
		return "涉及：\(parts.joined(separator: " · "))"
	}
}

struct AIJobAnomalySection: Equatable, Sendable {
	let totalCount: Int
	let groups: [AIJobFailureGroup]
}

// MARK: - Activity

struct AIJobActivityItem: Equatable, Sendable {
	let kind: AIJobKind
	let count: Int
}

struct AIJobActivitySection: Equatable, Sendable {
	let items: [AIJobActivityItem]
	let totalCount: Int
	let lastActivityText: String?
}

// MARK: - View model

struct AIJobStatusViewModel: Equatable, Sendable {
	let scopeTitle: String
	let scopeSubtitle: String
	let scopeKind: AIJobScopeKind
	let headline: AIJobHeadline
	let tiles: [AIJobTile]
	let showsGatewayBanner: Bool
	let coverage: AIJobCoverage?
	let coverageUnavailable: Bool
	let coverageEmptyMessage: String?
	let anomalies: AIJobAnomalySection?
	let activity: AIJobActivitySection?
	let emptyStateLines: [String]
	let footerLines: [String]

	func tile(_ title: String) -> AIJobTile? {
		tiles.first { $0.title == title }
	}
}

struct AIJobStatusInput: Sendable {
	let scope: AIJobScope
	let now: Date
	let hasAPIKey: Bool
	let activeJobs: [AIJob]
	let foldedFailures: [AIJob]
	let completedTodayJobs: [AIJob]
	let articlesByID: [String: AIJobArticleInfo]
	let timelineArticleCount: Int
	let unreadOnly: Bool
	var coverage: AIJobCoverage?
	var coverageQueryFailed = false
	var feedDisplayNames: [String: String] = [:]
	var expandedFailureGroups: Set<AIJobFailureGroupKey> = []
	var retryingFailureGroups: Set<AIJobFailureGroupKey> = []
	var failureRetryNotices: [AIJobFailureGroupKey: String] = [:]
}

enum AIJobStatusModel {

	private static let failedWindow: TimeInterval = 24 * 60 * 60
	private static let unknownFeedName = "未知订阅源"

	static func build(_ input: AIJobStatusInput) -> AIJobStatusViewModel {
		let activeInScope = input.activeJobs.filter { inScope($0, input) }
		let runningJobs = activeInScope.filter { $0.status == .running }
		let pendingJobs = activeInScope.filter { $0.status == .pending }
		let retryJobs = activeInScope.filter { $0.status == .retry }
		let activeKeys = Set(activeInScope.compactMap { job -> AIJobKey? in
			switch job.status {
			case .pending, .running, .retry:
				return AIJobKey(articleID: job.articleID, kind: job.kind)
			case .completed, .failed:
				return nil
			}
		})

		let failedInScope = input.foldedFailures.filter {
			$0.status == .failed
				&& ($0.finishedAt ?? .distantPast) >= input.now.addingTimeInterval(-failedWindow)
				&& !activeKeys.contains(AIJobKey(articleID: $0.articleID, kind: $0.kind))
				&& inScope($0, input)
		}

		let dayStart = startOfDay(for: input.now)
		let completedToday = input.completedTodayJobs.filter {
			$0.status == .completed
				&& ($0.finishedAt ?? .distantPast) >= dayStart
				&& inScope($0, input)
		}

		let runningRewriteCount = Set(
			runningJobs.filter { $0.kind == .rewrite }.map(\.articleID)
		).count
		let runningTranslationCount = Set(
			runningJobs.filter { $0.kind != .rewrite }.map(\.articleID)
		).count

		let headline = headline(
			hasAPIKey: input.hasAPIKey,
			runningRewriteArticleCount: runningRewriteCount,
			runningTranslationArticleCount: runningTranslationCount,
			pendingCount: pendingJobs.count
		)

		let retryCount = uniqueRetries(from: retryJobs).count
		let tiles = [
			AIJobTile(title: "进行中", count: runningJobs.count, tone: runningJobs.isEmpty ? .neutral : .accent),
			AIJobTile(title: "排队", count: pendingJobs.count, tone: .neutral),
			AIJobTile(title: "等待重试", count: retryCount, tone: retryCount > 0 ? .retry : .neutral),
			AIJobTile(title: "失败", count: failedInScope.count, tone: failedInScope.isEmpty ? .neutral : .danger)
		]

		let anomalies = makeAnomalies(failedInScope, input: input)
		let activity = makeActivity(completedToday, input: input)
		let coverage = input.coverageQueryFailed ? nil : input.coverage
		let hasWork = !runningJobs.isEmpty || !pendingJobs.isEmpty || retryCount > 0 || !failedInScope.isEmpty

		return AIJobStatusViewModel(
			scopeTitle: input.scope.name,
			scopeSubtitle: subtitle(for: input.scope, articleCount: input.timelineArticleCount),
			scopeKind: input.scope.kind,
			headline: headline,
			tiles: tiles,
			showsGatewayBanner: !input.hasAPIKey,
			coverage: coverage,
			coverageUnavailable: input.coverageQueryFailed,
			coverageEmptyMessage: coverage?.total == 0 ? "列表内没有文章" : nil,
			anomalies: anomalies,
			activity: activity,
			emptyStateLines: hasWork ? [] : emptyStateLines(hasAPIKey: input.hasAPIKey),
			footerLines: ["任务数字按任务条目计，头部篇数来自当前时间线。"]
		)
	}

	// MARK: - Scope

	private static func inScope(_ job: AIJob, _ input: AIJobStatusInput) -> Bool {
		guard let article = input.articlesByID[job.articleID] else {
			// Without the article there is no honest way to say which scope it
			// belongs to, so it is counted as out of scope for every panel.
			return false
		}
		if input.unreadOnly, article.read {
			// The timeline is hiding read articles, so their tasks are not
			// part of what the list shows.
			return false
		}
		return input.scope.contains(article, now: input.now)
	}

	static func subtitle(for scope: AIJobScope, articleCount: Int) -> String {
		switch scope.kind {
		case .feed:
			return "订阅源 · \(articleCount) 篇"
		case .folder:
			return "文件夹 · \(scope.feedCount) 个订阅源 · \(articleCount) 篇"
		case .today:
			return "智能订阅 · 近 24 小时 · \(articleCount) 篇"
		case .allUnread:
			return "智能订阅 · 全部未读 · \(articleCount) 篇"
		case .starred:
			return "智能订阅 · 已收藏 · \(articleCount) 篇"
		}
	}

	private static func emptyStateLines(hasAPIKey: Bool) -> [String] {
		if hasAPIKey {
			return [
				"新文章：改写、标题翻译自动排队",
				"正文翻译：打开「翻译」标签时开始"
			]
		}
		return [
			"配置 AI 网关后，新文章才会开始排队",
			"正文翻译：打开「翻译」标签时开始"
		]
	}

	// MARK: - Headline

	static func headline(
		hasAPIKey: Bool,
		runningRewriteArticleCount: Int,
		runningTranslationArticleCount: Int,
		pendingCount: Int
	) -> AIJobHeadline {
		guard hasAPIKey else {
			return AIJobHeadline(text: "AI 网关未配置", tone: .red)
		}
		let rewrites = runningRewriteArticleCount
		let translations = runningTranslationArticleCount
		switch (rewrites > 0, translations > 0) {
		case (true, true):
			return AIJobHeadline(text: "正在改写 \(rewrites) 篇、翻译 \(translations) 篇", tone: .green)
		case (true, false):
			return AIJobHeadline(text: "正在改写 \(rewrites) 篇", tone: .green)
		case (false, true):
			return AIJobHeadline(text: "正在翻译 \(translations) 篇", tone: .green)
		case (false, false):
			guard pendingCount > 0 else {
				return AIJobHeadline(text: "没有正在进行中的任务", tone: .gray)
			}
			return AIJobHeadline(text: "\(pendingCount) 项排队中", tone: .yellow)
		}
	}

	// MARK: - Attention

	private static func makeAnomalies(_ failedJobs: [AIJob], input: AIJobStatusInput) -> AIJobAnomalySection? {
		guard !failedJobs.isEmpty else {
			return nil
		}
		let sorted = failedJobs.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
		let grouped = Dictionary(grouping: sorted) { job in
			AIJobFailureGroupKey(kind: job.kind, reason: failureErrorText(job))
		}

		let groups = grouped.map { key, jobs -> AIJobFailureGroup in
			var feedCounts: [String: (name: String, count: Int)] = [:]
			var unknownCount = 0
			var seenRequests: Set<AIJobRequeueRequest> = []
			var retryableJobs: [AIJobRequeueRequest] = []

			for job in jobs {
				if let article = input.articlesByID[job.articleID] {
					let name = feedName(for: article, input: input)
					let current = feedCounts[article.feedID] ?? (name: name, count: 0)
					feedCounts[article.feedID] = (name: current.name, count: current.count + 1)
				} else {
					unknownCount += 1
				}
				let request = AIJobRequeueRequest(articleID: job.articleID, kind: job.kind)
				if seenRequests.insert(request).inserted {
					retryableJobs.append(request)
				}
			}
			if unknownCount > 0 {
				feedCounts["__unknown__"] = (name: unknownFeedName, count: unknownCount)
			}

			let perFeedCounts = feedCounts.values
				.map { AIJobFailureFeedCount(feedName: $0.name, count: $0.count) }
				.sorted { lhs, rhs in
					if lhs.count != rhs.count {
						return lhs.count > rhs.count
					}
					return lhs.feedName < rhs.feedName
				}

			return AIJobFailureGroup(
				key: key,
				kind: key.kind,
				reason: key.reason,
				count: jobs.count,
				perFeedCounts: perFeedCounts,
				retryableJobs: retryableJobs,
				isExpanded: input.expandedFailureGroups.contains(key),
				isRetrying: input.retryingFailureGroups.contains(key),
				retryNotice: input.failureRetryNotices[key]
			)
		}.sorted { lhs, rhs in
			if kindRank(lhs.kind) != kindRank(rhs.kind) {
				return kindRank(lhs.kind) < kindRank(rhs.kind)
			}
			if lhs.count != rhs.count {
				return lhs.count > rhs.count
			}
			return lhs.reason < rhs.reason
		}

		return AIJobAnomalySection(totalCount: failedJobs.count, groups: groups)
	}

	private static func feedName(for article: AIJobArticleInfo, input: AIJobStatusInput) -> String {
		if let name = input.feedDisplayNames[article.feedID], !name.isEmpty {
			return name
		}
		return AIJobCoverageBuilder.feedDisplayName(feedName: article.feedName, urlHost: nil, feedID: article.feedID)
	}

	private static func failureErrorText(_ job: AIJob) -> String {
		let error = job.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return error.isEmpty ? "未知错误" : error
	}

	private static func uniqueRetries(from jobs: [AIJob]) -> [AIJob] {
		let sorted = jobs.sorted { $0.availableAt < $1.availableAt }
		var seen: Set<AIJobKey> = []
		return sorted.filter { job in
			let key = AIJobKey(articleID: job.articleID, kind: job.kind)
			guard !seen.contains(key) else {
				return false
			}
			seen.insert(key)
			return true
		}
	}

	// MARK: - Activity

	private static func makeActivity(_ completedJobs: [AIJob], input: AIJobStatusInput) -> AIJobActivitySection? {
		guard !completedJobs.isEmpty else {
			return nil
		}
		let counts = Dictionary(grouping: completedJobs) { $0.kind }.mapValues { $0.count }
		let items = orderedKinds.compactMap { kind -> AIJobActivityItem? in
			guard let count = counts[kind], count > 0 else {
				return nil
			}
			return AIJobActivityItem(kind: kind, count: count)
		}
		let lastFinished = completedJobs.compactMap(\.finishedAt).max()
		return AIJobActivitySection(
			items: items,
			totalCount: completedJobs.count,
			lastActivityText: lastFinished.map { "上次活动 \(relativeTime($0, now: input.now))" }
		)
	}

	// MARK: - Helpers

	private static let orderedKinds: [AIJobKind] = [.rewrite, .bodyTranslation, .titleTranslation]

	private static func kindRank(_ kind: AIJobKind) -> Int {
		switch kind {
		case .rewrite: return 0
		case .bodyTranslation: return 1
		case .titleTranslation: return 2
		}
	}

	static func kindLabel(_ kind: AIJobKind) -> String {
		switch kind {
		case .bodyTranslation: return "正文翻译"
		case .titleTranslation: return "标题翻译"
		case .rewrite: return "改写"
		}
	}

	private struct AIJobKey: Hashable {
		let articleID: String
		let kind: AIJobKind
	}

	static func startOfDay(for now: Date, calendar: Calendar = .current) -> Date {
		calendar.startOfDay(for: now)
	}

	static func relativeTime(_ date: Date, now: Date) -> String {
		let interval = now.timeIntervalSince(date)
		if interval < 60 {
			return "刚刚"
		}
		if interval < 60 * 60 {
			return "\(Int(interval / 60)) 分钟前"
		}
		return "\(Int(interval / (60 * 60))) 小时前"
	}
}

// MARK: - Batch retry

struct AIJobRetryOutcome: Equatable, Sendable {
	let submittedCount: Int
	let skippedCount: Int
}

@MainActor
protocol AIJobRetryEnqueuing {
	func enqueue(_ request: AIJobRequeueRequest) async -> Bool
}

/// Runs one anomaly group's retry through the executor's manual enqueue paths.
/// The reservation is taken before the first `await`, so two clicks in the same
/// run loop turn cannot both submit the same article and kind.
@MainActor
final class AIJobFailureRetryRunner {

	private let enqueuer: AIJobRetryEnqueuing
	private var reservations = AIEnqueueReservations()

	init(enqueuer: AIJobRetryEnqueuing) {
		self.enqueuer = enqueuer
	}

	func retry(_ requests: [AIJobRequeueRequest]) async -> AIJobRetryOutcome {
		var seen: Set<AIJobRequeueRequest> = []
		var submitted = 0
		var skipped = 0
		for request in requests {
			guard seen.insert(request).inserted else {
				skipped += 1
				continue
			}
			let key = "\(request.kind.rawValue):\(request.articleID)"
			guard !reservations.contains(key), reservations.reserve(key) else {
				skipped += 1
				continue
			}
			let enqueued = await enqueuer.enqueue(request)
			reservations.release(key)
			if enqueued {
				submitted += 1
			} else {
				skipped += 1
			}
		}
		return AIJobRetryOutcome(submittedCount: submitted, skippedCount: skipped)
	}
}

/// The production bridge from a retry request to `AIJobExecutor`'s manual
/// methods. Title translations have no enqueue result, so this checks whether
/// the article gained an active title job.
@MainActor
final class AIJobExecutorRetryEnqueuer: AIJobRetryEnqueuing {

	private let executor: AIJobExecutor
	private let store: AIStore

	init(executor: AIJobExecutor = .shared, store: AIStore = AIEnvironment.shared.store) {
		self.executor = executor
		self.store = store
	}

	func enqueue(_ request: AIJobRequeueRequest) async -> Bool {
		switch request.kind {
		case .rewrite:
			return await executor.enqueueRewrite(articleID: request.articleID) == .enqueued
		case .bodyTranslation:
			return await executor.enqueueBodyTranslation(articleID: request.articleID) == .enqueued
		case .titleTranslation:
			let before = (try? await store.activeJobArticleIDs(kinds: [.titleTranslation])) ?? []
			await executor.enqueueTitleTranslation(articleID: request.articleID)
			let after = (try? await store.activeJobArticleIDs(kinds: [.titleTranslation])) ?? []
			return after.contains(request.articleID) && !before.contains(request.articleID)
		}
	}
}
