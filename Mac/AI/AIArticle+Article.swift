//
//  AIArticle+Article.swift
//  NetNewsWire
//

import AI
import Articles

extension AIArticle {

	/// Converts a timeline article into the value the AI module works with.
	init(article: Article) {
		self.init(
			id: article.articleID,
			title: article.title ?? "",
			contentHTML: article.contentHTML,
			contentText: article.contentText,
			url: article.preferredURL?.absoluteString,
			feedID: article.feedID,
			publishedAt: article.datePublished,
			isRead: article.status.read
		)
	}
}
