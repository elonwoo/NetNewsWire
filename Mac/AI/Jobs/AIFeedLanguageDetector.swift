//
//  AIFeedLanguageDetector.swift
//  NetNewsWire
//

import Account
import AI
import Articles
import Foundation
import os

/// Keeps a per-feed language verdict so Chinese feeds are turned off once,
/// without rescanning every feed at each launch.
///
/// The recent-article sampling and threshold live in `SubscriptionLanguageDetector`;
/// this class reads articles, caches the sample window in the AI store, and
/// applies the verdict to feed settings.
@MainActor
final class AIFeedLanguageDetector {

	static let shared = AIFeedLanguageDetector()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AILanguageDetector")

	private let store: AIStore
	private var observerToken: NSObjectProtocol?
	private var isRunning = false

	private init() {
		self.store = AIEnvironment.shared.store
	}

	func start() {
		installObserverIfNeeded()
		run()
	}

	private func installObserverIfNeeded() {
		guard observerToken == nil else {
			return
		}
		observerToken = NotificationCenter.default.addObserver(forName: .AccountDidDownloadArticles, object: nil, queue: .main) { [weak self] notification in
			guard let newArticles = notification.userInfo?[Account.UserInfoKey.newArticles] as? Set<Article>,
			      !newArticles.isEmpty else {
				return
			}
			Task { @MainActor in
				await self?.handleDownloadedArticles(newArticles)
			}
		}
	}

	private func run() {
		guard !isRunning else {
			return
		}
		isRunning = true
		Task { @MainActor [weak self] in
			await self?.scanFeedsWithoutSamples()
			self?.isRunning = false
		}
	}

	/// Feeds with a cached sample keep it; only feeds that were never judged are
	/// scanned here, so a relaunch no longer re-fetches every feed's articles.
	func scanFeedsWithoutSamples() async {
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() {
				// Nothing to turn off when both switches are already off.
				guard feed.aiRewriteEnabled || feed.aiTranslationEnabled else {
					continue
				}
				if let cached = ((try? await store.feedLanguageSample(for: feed.feedID)) ?? nil) {
					applyIfChinese(feed: feed, cache: cached)
					continue
				}
				let articles = await feed.fetchArticlesAsync().map { AIArticle(article: $0) }
				let recent = SubscriptionLanguageDetector.recentSample(from: articles)
				guard !recent.isEmpty else {
					continue
				}
				let sample = FeedLanguageSampleCache(entries: samples(for: recent))
				try? await store.saveFeedLanguageSample(feedID: feed.feedID, sample: sample)
				applyIfChinese(feed: feed, cache: sample)
			}
		}
	}

	/// Folds the newly downloaded articles into each feed's cached window. Only
	/// the new rows are judged; the older part of the window is reused.
	private func handleDownloadedArticles(_ articles: Set<Article>) async {
		var articlesByFeedID: [String: [AIArticle]] = [:]
		for article in articles {
			articlesByFeedID[article.feedID, default: []].append(AIArticle(article: article))
		}
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() {
				guard let feedArticles = articlesByFeedID[feed.feedID] else {
					continue
				}
				guard feed.aiRewriteEnabled || feed.aiTranslationEnabled else {
					continue
				}
				let cached = ((try? await store.feedLanguageSample(for: feed.feedID)) ?? nil) ?? FeedLanguageSampleCache()
				let merged = cached.merging(newEntries: samples(for: feedArticles))
				try? await store.saveFeedLanguageSample(feedID: feed.feedID, sample: merged)
				applyIfChinese(feed: feed, cache: merged)
			}
		}
	}

	private func samples(for articles: [AIArticle]) -> [FeedLanguageSample] {
		articles.map {
			FeedLanguageSample(articleID: $0.id, publishedAt: $0.publishedAt, isChinese: AutoWorkPolicy.isChinese($0))
		}
	}

	private func applyIfChinese(feed: Feed, cache: FeedLanguageSampleCache) {
		guard cache.isChinese else {
			return
		}
		if feed.applyAutomaticChineseOff() {
			Self.logger.info("Turned AI off for Chinese feed \(feed.feedID, privacy: .public)")
		}
	}
}
