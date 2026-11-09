//
//  AICatchUpPlannerTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AICatchUpPlannerTests {

	private let now = Date(timeIntervalSince1970: 1_700_000_000)

	private func chineseArticle(id: String, publishedAt: Date, feedID: String = "zh-feed") -> AIArticle {
		AIArticle(
			id: id,
			title: "标题",
			contentText: String(repeating: "中", count: 2500),
			feedID: feedID,
			publishedAt: publishedAt
		)
	}

	private func englishArticle(id: String, publishedAt: Date) -> AIArticle {
		AIArticle(
			id: id,
			title: "Title",
			contentText: String(repeating: "a", count: 100),
			publishedAt: publishedAt
		)
	}

	private func longEnglishArticle(id: String, publishedAt: Date, isRead: Bool = false) -> AIArticle {
		AIArticle(
			id: id,
			title: "Title",
			contentText: String(repeating: "a", count: 2500),
			publishedAt: publishedAt,
			isRead: isRead
		)
	}

	@Test func chineseLongArticleIsSkippedWithoutOverride() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs.isEmpty)
		#expect(plan.titleTranslationArticleIDs.isEmpty)
	}

	@Test func chineseLongArticleIsQueuedWhenTheFeedIsOverridden() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			chineseAllowedFeedIDs: ["zh-feed"],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs == ["zh"])
		#expect(plan.titleTranslationArticleIDs == ["zh"])
	}

	@Test func cachedRewriteWithMatchingHashIsSkipped() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let hash = AIContentHash.rewrite(for: article)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: ["zh": hash],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs.isEmpty)
		#expect(plan.titleTranslationArticleIDs.isEmpty)
	}

	@Test func legacyRewriteIsNotQueuedAutomatically() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: ["zh": AIContentHash.legacyRewrite(for: article)],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs.isEmpty)
	}

	@Test func chineseStaleRewriteIsNotQueuedWithoutOverride() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: ["zh": "stale"],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs.isEmpty)
	}

	@Test func englishStaleRewriteIsQueuedAgain() {
		let article = longEnglishArticle(id: "en", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: ["en": "stale"],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs == ["en"])
	}

	@Test func englishLongArticleNeedsRewriteAndTitleTranslation() {
		let article = longEnglishArticle(id: "en", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs == ["en"])
		#expect(plan.titleTranslationArticleIDs == ["en"])
	}

	@Test func cachedTitleWithMatchingHashIsSkipped() {
		let article = englishArticle(id: "en", publishedAt: now)
		let hash = AIContentHash.title(for: article)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: ["en": hash],
			limit: 200
		)

		#expect(plan.titleTranslationArticleIDs.isEmpty)
	}

	@Test func limitTruncatesInInputOrder() {
		let articles = (0..<3).map { index in
			englishArticle(id: "en\(index)", publishedAt: now.addingTimeInterval(-Double(index)))
		}
		let plan = AICatchUpPlanner.plan(
			articles: articles,
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			limit: 2
		)

		#expect(plan.titleTranslationArticleIDs == ["en0", "en1"])
	}

	@Test func articlesOlderThanTheRecencyWindowAreIgnored() {
		let old = now.addingTimeInterval(-3 * 24 * 60 * 60)
		let articles = [
			chineseArticle(id: "old-zh", publishedAt: old),
			englishArticle(id: "old-en", publishedAt: old)
		]
		let plan = AICatchUpPlanner.plan(
			articles: articles,
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan == AICatchUpPlan(rewriteArticleIDs: [], titleTranslationArticleIDs: []))
	}

	@Test func readArticlesAreNotPlanned() {
		let article = longEnglishArticle(id: "en-read", publishedAt: now, isRead: true)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan == AICatchUpPlan(rewriteArticleIDs: [], titleTranslationArticleIDs: []))
	}

	@Test func excludedRewriteNeverEntersRewriteIDs() {
		let article = longEnglishArticle(id: "en", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			rewriteExcludedArticleIDs: ["en"],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs.isEmpty)
		#expect(plan.titleTranslationArticleIDs == ["en"])
	}

	@Test func excludedRewriteDoesNotConsumeALimitSlot() {
		let articles = [
			longEnglishArticle(id: "en0", publishedAt: now),
			englishArticle(id: "en1", publishedAt: now.addingTimeInterval(-1)),
			englishArticle(id: "en2", publishedAt: now.addingTimeInterval(-2))
		]
		let plan = AICatchUpPlanner.plan(
			articles: articles,
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			rewriteExcludedArticleIDs: ["en0"],
			limit: 2
		)

		#expect(plan.rewriteArticleIDs.isEmpty)
		#expect(plan.titleTranslationArticleIDs == ["en0", "en1"])
	}

	@Test func excludedTranslationNeverEntersTitleIDs() {
		let article = longEnglishArticle(id: "en", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			translationExcludedArticleIDs: ["en"],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs == ["en"])
		#expect(plan.titleTranslationArticleIDs.isEmpty)
	}

	@Test func excludedTranslationDoesNotConsumeALimitSlot() {
		let articles = [
			englishArticle(id: "en0", publishedAt: now),
			englishArticle(id: "en1", publishedAt: now.addingTimeInterval(-1)),
			englishArticle(id: "en2", publishedAt: now.addingTimeInterval(-2))
		]
		let plan = AICatchUpPlanner.plan(
			articles: articles,
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			translationExcludedArticleIDs: ["en0"],
			limit: 2
		)

		#expect(plan.titleTranslationArticleIDs == ["en1", "en2"])
	}

	@Test func bothSwitchesOffProduceNoPlanForTheArticle() {
		let article = longEnglishArticle(id: "en", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			rewriteExcludedArticleIDs: ["en"],
			translationExcludedArticleIDs: ["en"],
			limit: 200
		)

		#expect(plan == AICatchUpPlan(rewriteArticleIDs: [], titleTranslationArticleIDs: []))
	}
}
