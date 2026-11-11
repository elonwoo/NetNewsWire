//
//  AIContentHashTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIContentHashTests {

	private func article(contentText: String? = nil, contentHTML: String? = nil) -> AIArticle {
		AIArticle(id: "a", title: "Title", contentHTML: contentHTML, contentText: contentText, url: "https://example.com/post", feedID: "feed")
	}

	private func longArticle() -> AIArticle {
		article(contentHTML: "<p>" + String(repeating: "a", count: 2000) + "</p>")
	}

	@Test func rewriteAndBodyHashesAreVersioned() {
		let value = article(contentHTML: "<p>Body</p>")
		#expect(AIContentHash.rewrite(for: value).hasPrefix("r2:"))
		#expect(AIContentHash.body(for: value).hasPrefix("b2:"))
		#expect(!AIContentHash.title(for: value).hasPrefix("r2:"))
		#expect(!AIContentHash.title(for: value).hasPrefix("b2:"))
	}

	@Test func rewriteHashChangesWithContentAndKind() {
		let first = article(contentHTML: "<p>Body</p>")
		let second = article(contentHTML: "<p>Different</p>")
		#expect(AIContentHash.rewrite(for: first) != AIContentHash.rewrite(for: second))

		let paper = AIArticle(id: "paper", title: "Title", contentHTML: "<p>Body</p>", url: "https://arxiv.org/abs/1")
		#expect(AIContentHash.rewrite(for: first) != AIContentHash.rewrite(for: paper))
	}

	@Test func rewriteStateMapsLegacyToPipelineOutdated() {
		let value = longArticle()
		let state = AIContentHash.rewriteState(stored: AIContentHash.legacyRewrite(for: value), article: value)
		#expect(state == .pipelineOutdated)
	}

	@Test func rewriteStateMapsChangedContent() {
		let value = article(contentHTML: "<p>Body</p>")
		#expect(AIContentHash.rewriteState(stored: "stale", article: value) == .contentChanged)
	}

	@Test func fullTextProvenanceIsIgnoredByRewriteState() {
		let value = article(contentHTML: "<p>Body</p>")
		let fullTextHash = "ft:" + AIContentHash.rewrite(for: value)

		#expect(AIContentHash.rewriteState(stored: fullTextHash, article: value) == .current)
		#expect(AIContentHash.isRewriteUpToDate(stored: fullTextHash, article: value))
	}

	@Test func shortBodyFeedRewriteIsCurrent() {
		let value = article(contentHTML: "<p>" + String(repeating: "a", count: 800) + "</p>")
		let feedHash = AIContentHash.rewrite(for: value)

		#expect(AIContentHash.rewriteState(stored: feedHash, article: value) == .current)
		#expect(AIContentHash.isRewriteUpToDate(stored: feedHash, article: value))
		#expect(AIContentHash.rewriteState(stored: "ft:" + feedHash, article: value) == .current)
		#expect(AIContentHash.isRewriteUpToDate(stored: "ft:" + feedHash, article: value))
	}

	@Test func rewriteStateMapsMissingCurrentAndContentChanged() {
		let value = longArticle()

		#expect(AIContentHash.rewriteState(stored: nil, article: value) == .missing)
		#expect(AIContentHash.rewriteState(stored: "", article: value) == .missing)
		#expect(AIContentHash.rewriteState(stored: AIContentHash.rewrite(for: value), article: value) == .current)
		#expect(AIContentHash.rewriteState(stored: "old", article: value) == .contentChanged)
	}

	@Test func rewriteUpToDateAcceptsCurrentAndPipelineOutdated() {
		let value = longArticle()
		#expect(AIContentHash.isRewriteUpToDate(stored: AIContentHash.rewrite(for: value), article: value))
		#expect(AIContentHash.isRewriteUpToDate(stored: AIContentHash.legacyRewrite(for: value), article: value))
		#expect(!AIContentHash.isRewriteUpToDate(stored: nil, article: value))
		#expect(!AIContentHash.isRewriteUpToDate(stored: "stale", article: value))
	}

	@Test func titleHashBackwardsCompatibility() {
		let value = article(contentText: "Body", contentHTML: "<p>Body</p>")

		#expect(AIContentHash.matchesTitleHash(AIContentHash.title(for: value), article: value))
		#expect(AIContentHash.matchesTitleHash(AIContentHash.body(for: value), article: value))
		#expect(AIContentHash.matchesTitleHash(ContentFingerprint.legacyBody(for: value), article: value))
		#expect(!AIContentHash.matchesTitleHash(AIContentHash.rewrite(for: value), article: value))
	}
}
