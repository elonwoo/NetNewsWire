//
//  AIRewriteViewControllerTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite @MainActor
struct AIRewriteViewControllerTests {

	private func article(id: String = "article", contentLength: Int) -> AIArticle {
		AIArticle(
			id: id,
			title: "English title",
			contentHTML: "<p>" + String(repeating: "a", count: contentLength) + "</p>",
			url: "https://example.com/\(id)",
			feedID: "feed"
		)
	}

	private func rewrite(article: AIArticle, hash: String) -> AI.Rewrite {
		AI.Rewrite(
			articleID: article.id,
			title: article.title,
			bodyMarkdown: "已有改写",
			model: "old-model",
			contentHash: hash,
			createdAt: Date(),
			updatedAt: Date()
		)
	}

	@Test func shortFeedRewriteIsStaleButFullTextRewriteIsCurrent() {
		let value = article(contentLength: 800)
		let feedHash = AIContentHash.rewrite(for: value)

		#expect(AIRewriteViewController.isStale(rewrite: rewrite(article: value, hash: feedHash), article: value))
		#expect(!AIRewriteViewController.isStale(rewrite: rewrite(article: value, hash: "ft:" + feedHash), article: value))
	}

	@Test func longFeedRewriteIsCurrent() {
		let value = article(contentLength: 2500)
		let hash = AIContentHash.rewrite(for: value)

		#expect(!AIRewriteViewController.isStale(rewrite: rewrite(article: value, hash: hash), article: value))
	}

	@Test func removalRefreshesOnlyTheMatchingVisibleRewrite() {
		#expect(AIRewriteViewController.shouldRefreshAfterRewriteRemoval(eventArticleID: "a", paneArticleID: "a", isShowingRewrite: true))
		#expect(!AIRewriteViewController.shouldRefreshAfterRewriteRemoval(eventArticleID: "a", paneArticleID: "a", isShowingRewrite: false))
		#expect(!AIRewriteViewController.shouldRefreshAfterRewriteRemoval(eventArticleID: "a", paneArticleID: "b", isShowingRewrite: true))
		#expect(!AIRewriteViewController.shouldRefreshAfterRewriteRemoval(eventArticleID: nil, paneArticleID: "a", isShowingRewrite: true))
		#expect(!AIRewriteViewController.shouldRefreshAfterRewriteRemoval(eventArticleID: "a", paneArticleID: nil, isShowingRewrite: true))
	}
}
