//
//  AIArticleResolver.swift
//  NetNewsWire
//

import Account
import AI
import Articles

@MainActor
protocol AIArticleResolving: Sendable {
	func article(for articleID: String) async -> AIArticle?
}

/// Turns the article ID stored on a job back into the value the AI module
/// works with. Article IDs are only unique inside an account database, so
/// every account gets asked in turn.
@MainActor
final class AIArticleResolver: AIArticleResolving {

	private let accountManager: AccountManager

	init(accountManager: AccountManager = .shared) {
		self.accountManager = accountManager
	}

	func article(for articleID: String) async -> AIArticle? {
		for account in accountManager.accounts {
			let articles = await account.fetchArticlesAsync(.articleIDs([articleID]))
			if let article = articles.first(where: { $0.articleID == articleID }) {
				return AIArticle(article: article)
			}
		}
		return nil
	}
}
