//
//  AITitleBatchPolicyTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AITitleBatchPolicyTests {

	private func article(id: String, feedID: String?) -> AIArticle {
		AIArticle(id: id, title: "Title", contentText: "body", feedID: feedID)
	}

	@Test func claimedArticleLeadsTheBatch() {
		let claimed = article(id: "claimed", feedID: "feed-a")
		let pending = [
			"other": article(id: "other", feedID: "feed-b")
		]
		let batch = AITitleBatchPolicy.batch(article: claimed, pending: pending, translationDisabledFeedIDs: [], limit: 20)

		#expect(batch.map(\.id) == ["claimed", "other"])
	}

	@Test func disabledFeedIsDroppedFromTheBatch() {
		let claimed = article(id: "claimed", feedID: "feed-a")
		let pending = [
			"blocked": article(id: "blocked", feedID: "feed-b"),
			"allowed": article(id: "allowed", feedID: "feed-c")
		]
		let batch = AITitleBatchPolicy.batch(article: claimed, pending: pending, translationDisabledFeedIDs: ["feed-b"], limit: 20)

		#expect(batch.map(\.id) == ["claimed", "allowed"])
	}

	@Test func claimedArticleFromADisabledFeedYieldsNoBatch() {
		let claimed = article(id: "claimed", feedID: "feed-a")
		let batch = AITitleBatchPolicy.batch(article: claimed, pending: [:], translationDisabledFeedIDs: ["feed-a"], limit: 20)

		#expect(batch.isEmpty)
	}

	@Test func limitCapsTheBatch() {
		let claimed = article(id: "claimed", feedID: "feed-a")
		let pending = [
			"a": article(id: "a", feedID: "feed-b"),
			"b": article(id: "b", feedID: "feed-b")
		]
		let batch = AITitleBatchPolicy.batch(article: claimed, pending: pending, translationDisabledFeedIDs: [], limit: 2)

		#expect(batch.count == 2)
		#expect(batch.first?.id == "claimed")
	}

	@Test func zeroLimitYieldsNoBatch() {
		let claimed = article(id: "claimed", feedID: "feed-a")
		let batch = AITitleBatchPolicy.batch(article: claimed, pending: [:], translationDisabledFeedIDs: [], limit: 0)

		#expect(batch.isEmpty)
	}
}
