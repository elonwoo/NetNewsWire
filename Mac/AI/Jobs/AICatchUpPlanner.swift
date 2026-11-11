//
//  AICatchUpPlanner.swift
//  NetNewsWire
//

import AI
import Foundation

struct AICatchUpPlan: Equatable {
	var rewriteArticleIDs: [String]
	var titleTranslationArticleIDs: [String]
}

/// Decides which recent articles are still missing cached AI work.
///
/// The caller supplies articles in reverse chronological order and resolves the
/// cache state, so this stays a pure function that is easy to test.
enum AICatchUpPlanner {

	/// - Parameters:
	///   - articles: Recent articles sorted by publication date, newest first.
	///   - cachedRewrites: Article ID to the content hash of its stored rewrite.
	///   - cachedTitleHashes: Article ID to the content hash stored with a
	///     non-empty translated title.
	///   - rewriteExcludedArticleIDs: Articles whose feeds have rewrite turned
	///     off. They never enter `rewriteArticleIDs` and never consume a limit
	///     slot.
	///   - translationExcludedArticleIDs: Articles whose feeds have translation
	///     turned off. They never enter `titleTranslationArticleIDs`.
	///   - chineseAllowedFeedIDs: Feeds whose language override lets Chinese
	///     articles keep automatic work.
	///   - limit: Maximum number of jobs in the returned plan.
	static func plan(articles: [AIArticle],
					 now: Date,
					 cachedRewrites: [String: String],
					 cachedTitleHashes: [String: String],
					 rewriteExcludedArticleIDs: Set<String> = [],
					 translationExcludedArticleIDs: Set<String> = [],
					 chineseAllowedFeedIDs: Set<String> = [],
					 limit: Int) -> AICatchUpPlan {
		var plan = AICatchUpPlan(rewriteArticleIDs: [], titleTranslationArticleIDs: [])
		guard limit > 0 else {
			return plan
		}

		// Filter by date before hashing so old articles never cost a hash.
		let cutoff = now.addingTimeInterval(-AutoWorkPolicy.recencyWindow)
		for article in articles {
			guard plan.rewriteArticleIDs.count + plan.titleTranslationArticleIDs.count < limit else {
				break
			}
			guard let publishedAt = article.publishedAt, publishedAt >= cutoff else {
				continue
			}

			let chineseAllowed = AIArticleLanguageGate.allows(article, chineseAllowedFeedIDs: chineseAllowedFeedIDs)
			if AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: chineseAllowed),
			   !rewriteExcludedArticleIDs.contains(article.id),
			   hasUsableRewriteBody(article),
			   !isRewriteUpToDate(article, cachedRewrites: cachedRewrites),
			   plan.rewriteArticleIDs.count + plan.titleTranslationArticleIDs.count < limit {
				plan.rewriteArticleIDs.append(article.id)
			}
			if AutoWorkPolicy.shouldTranslate(article, now: now, chineseAllowed: chineseAllowed),
			   !translationExcludedArticleIDs.contains(article.id),
			   !isTitleUpToDate(article, cachedTitleHashes: cachedTitleHashes),
			   plan.rewriteArticleIDs.count + plan.titleTranslationArticleIDs.count < limit {
				plan.titleTranslationArticleIDs.append(article.id)
			}
		}
		return plan
	}
}

private extension AICatchUpPlanner {

	/// An article whose feed body cannot be rewritten would be skipped at
	/// execution time, so catch-up never queues it in the first place.
	static func hasUsableRewriteBody(_ article: AIArticle) -> Bool {
		guard AIRewriteKindSelector.kind(for: article) == .article else {
			return true
		}
		return AIFullTextFetcher.hasUsableFeedBody(article)
	}

	static func isRewriteUpToDate(_ article: AIArticle, cachedRewrites: [String: String]) -> Bool {
		guard let cachedHash = cachedRewrites[article.id] else {
			return false
		}
		return AIContentHash.isRewriteUpToDate(stored: cachedHash, article: article)
	}

	static func isTitleUpToDate(_ article: AIArticle, cachedTitleHashes: [String: String]) -> Bool {
		guard let cachedHash = cachedTitleHashes[article.id] else {
			return false
		}
		return AIContentHash.matchesTitleHash(cachedHash, article: article)
	}
}
