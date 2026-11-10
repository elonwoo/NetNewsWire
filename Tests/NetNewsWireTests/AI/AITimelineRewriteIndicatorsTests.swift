//
//  AITimelineRewriteIndicatorsTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite @MainActor
struct AITimelineRewriteIndicatorsTests {

	@Test func removingARejectedRewriteClearsTheGreenDot() {
		let remaining = TimelineViewController.rewrittenArticleIDsAfterRemoval(["article", "other"], articleID: "article")

		#expect(remaining == ["other"])
		let dot = TimelineDotPolicy.dot(
			isUnread: true,
			isStarred: false,
			rewriteEnabled: true,
			hasRewrite: remaining.contains("article"),
			translationEnabled: true,
			hasTranslation: false
		)
		#expect(dot == .blue)
	}

	@Test func removalKeepsOtherRewriteIndicators() {
		let remaining = TimelineViewController.rewrittenArticleIDsAfterRemoval(["article", "other"], articleID: "article")

		let dot = TimelineDotPolicy.dot(
			isUnread: true,
			isStarred: false,
			rewriteEnabled: true,
			hasRewrite: remaining.contains("other"),
			translationEnabled: true,
			hasTranslation: false
		)
		#expect(dot == .green)
	}
}
