//
//  AIRewriteKindSelectorTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIRewriteKindSelectorTests {

	@Test func arxivLinkUsesPaperRewrite() {
		#expect(AIRewriteKindSelector.kind(url: "https://arxiv.org/abs/2501.00001", feedID: nil) == .paper)
		#expect(AIRewriteKindSelector.kind(url: "https://export.arxiv.org/pdf/2501.00001", feedID: nil) == .paper)
	}

	@Test func huggingFaceLinkUsesPaperRewrite() {
		#expect(AIRewriteKindSelector.kind(url: "https://huggingface.co/papers/2501.00001", feedID: nil) == .paper)
	}

	@Test func productHuntLinkUsesProductHuntRewrite() {
		#expect(AIRewriteKindSelector.kind(url: "https://www.producthunt.com/posts/some-product", feedID: nil) == .productHunt)
	}

	@Test func otherLinksUseArticleRewrite() {
		#expect(AIRewriteKindSelector.kind(url: "https://example.com/post", feedID: nil) == .article)
		#expect(AIRewriteKindSelector.kind(url: nil, feedID: nil) == .article)
	}

	@Test func feedIDIsUsedWhenURLIsMissing() {
		#expect(AIRewriteKindSelector.kind(url: nil, feedID: "https://arxiv.org/rss/cs.AI") == .paper)
		#expect(AIRewriteKindSelector.kind(url: nil, feedID: "https://www.producthunt.com/feed") == .productHunt)
	}

	@Test func articleURLWinsOverFeedID() {
		#expect(AIRewriteKindSelector.kind(url: "https://example.com/post", feedID: "https://arxiv.org/rss/cs.AI") == .article)
	}
}
