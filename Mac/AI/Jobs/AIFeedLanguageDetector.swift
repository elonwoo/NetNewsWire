//
//  AIFeedLanguageDetector.swift
//  NetNewsWire
//

import Account
import AI
import Foundation
import os

/// Runs the subscription-level Chinese detection at launch and after every
/// account refresh.
///
/// The recent-article sampling and threshold live in `SubscriptionLanguageDetector`;
/// this class only reads articles and applies the result to feed settings.
@MainActor
final class AIFeedLanguageDetector {

	static let shared = AIFeedLanguageDetector()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AILanguageDetector")

	private var observerToken: NSObjectProtocol?
	private var isRunning = false

	private init() {
	}

	func start() {
		installObserverIfNeeded()
		run()
	}

	private func installObserverIfNeeded() {
		guard observerToken == nil else {
			return
		}
		observerToken = NotificationCenter.default.addObserver(forName: .AccountRefreshDidFinish, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.run()
			}
		}
	}

	private func run() {
		guard !isRunning else {
			return
		}
		isRunning = true
		Task { @MainActor [weak self] in
			await self?.detect()
			self?.isRunning = false
		}
	}

	func detect() async {
		for account in AccountManager.shared.accounts {
			for feed in account.flattenedFeeds() {
				// Nothing to turn off when both switches are already off.
				guard feed.aiRewriteEnabled || feed.aiTranslationEnabled else {
					continue
				}
				let articles = await feed.fetchArticlesAsync().map { AIArticle(article: $0) }
				let recent = SubscriptionLanguageDetector.recentSample(from: articles)
				guard !recent.isEmpty else {
					continue
				}
				let samples = recent.map { AutoWorkPolicy.isChinese($0) }
				guard SubscriptionLanguageDetector.isChineseSubscription(samples) else {
					continue
				}
				if feed.applyAutomaticChineseOff() {
					Self.logger.info("Turned AI off for Chinese feed \(feed.feedID, privacy: .public)")
				}
			}
		}
	}
}
