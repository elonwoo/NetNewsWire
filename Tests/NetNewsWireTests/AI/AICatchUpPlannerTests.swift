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

	private func chineseArticle(id: String, publishedAt: Date) -> AIArticle {
		AIArticle(
			id: id,
			title: "标题",
			contentText: String(repeating: "中", count: 2500),
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

	private func longEnglishArticle(id: String, publishedAt: Date) -> AIArticle {
		AIArticle(
			id: id,
			title: "Title",
			contentText: String(repeating: "a", count: 2500),
			publishedAt: publishedAt
		)
	}

	@Test func chineseLongArticleNeedsRewrite() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: [:],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs == ["zh"])
		#expect(plan.titleTranslationArticleIDs.isEmpty)
	}

	@Test func cachedRewriteWithMatchingHashIsSkipped() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let hash = AIContentHash.titleOrRewrite(for: article)
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

	@Test func cachedRewriteWithStaleHashIsQueuedAgain() {
		let article = chineseArticle(id: "zh", publishedAt: now)
		let plan = AICatchUpPlanner.plan(
			articles: [article],
			now: now,
			cachedRewrites: ["zh": "stale"],
			cachedTitleHashes: [:],
			limit: 200
		)

		#expect(plan.rewriteArticleIDs == ["zh"])
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
		let hash = AIContentHash.titleOrRewrite(for: article)
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

	@Test func articlesOlderThanSevenDaysAreIgnored() {
		let old = now.addingTimeInterval(-8 * 24 * 60 * 60)
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
}
