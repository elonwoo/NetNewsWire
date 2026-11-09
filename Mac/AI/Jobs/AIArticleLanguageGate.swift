//
//  AIArticleLanguageGate.swift
//  NetNewsWire
//

import Account
import AI
import Articles

/// The single article-level admission rule for AI work.
///
/// AI is allowed when the feed switches allow it AND the article is not Chinese
/// or its feed has `aiLanguageOverride` set. The pane tabs, manual rewrite, body
/// translation and the job executor all consult this rule.
enum AIArticleLanguageGate {

	static func allows(_ article: AIArticle, chineseAllowed: Bool) -> Bool {
		chineseAllowed || !AutoWorkPolicy.isChinese(article)
	}

	static func allows(_ article: AIArticle, chineseAllowedFeedIDs: Set<String>) -> Bool {
		guard AutoWorkPolicy.isChinese(article) else {
			return true
		}
		guard let feedID = article.feedID else {
			return false
		}
		return chineseAllowedFeedIDs.contains(feedID)
	}

	@MainActor
	static func allows(_ article: Article) -> Bool {
		allows(AIArticle(article: article), chineseAllowed: article.feed?.aiLanguageOverride ?? false)
	}
}
