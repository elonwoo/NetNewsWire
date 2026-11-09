//
//  AIRewriteAdmissionTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIRewriteAdmissionTests {

	@Test func rewriteDisabledFeedIsBlocked() {
		#expect(AIRewriteAdmission.allowsRewrite(feedID: "flagged", rewriteDisabledFeedIDs: ["flagged"]) == false)
	}

	@Test func rewriteEnabledFeedIsAllowed() {
		#expect(AIRewriteAdmission.allowsRewrite(feedID: "other", rewriteDisabledFeedIDs: ["flagged"]) == true)
	}

	@Test func missingFeedIDIsAllowed() {
		#expect(AIRewriteAdmission.allowsRewrite(feedID: nil, rewriteDisabledFeedIDs: ["flagged"]) == true)
	}

	@Test func translationDisabledFeedIsBlocked() {
		#expect(AIRewriteAdmission.allowsTranslation(feedID: "flagged", translationDisabledFeedIDs: ["flagged"]) == false)
	}

	@Test func translationEnabledFeedIsAllowed() {
		#expect(AIRewriteAdmission.allowsTranslation(feedID: "other", translationDisabledFeedIDs: ["flagged"]) == true)
	}

	@Test func missingFeedIDIsAllowedForTranslation() {
		#expect(AIRewriteAdmission.allowsTranslation(feedID: nil, translationDisabledFeedIDs: ["flagged"]) == true)
	}

	@Test func theTwoSwitchesAreIndependent() {
		#expect(AIRewriteAdmission.allowsRewrite(feedID: "flagged", rewriteDisabledFeedIDs: []) == true)
		#expect(AIRewriteAdmission.allowsTranslation(feedID: "other", translationDisabledFeedIDs: ["flagged"]) == true)
	}
}
