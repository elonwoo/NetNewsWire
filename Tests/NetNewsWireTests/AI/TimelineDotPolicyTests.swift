//
//  TimelineDotPolicyTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct TimelineDotPolicyTests {

	@Test func unreadWithoutAIWorkIsBlue() {
		let dot = TimelineDotPolicy.dot(isUnread: true, isStarred: false, rewriteEnabled: true, hasRewrite: false, translationEnabled: true, hasTranslation: false)
		#expect(dot == .blue)
	}

	@Test func completedRewriteIsGreen() {
		let dot = TimelineDotPolicy.dot(isUnread: true, isStarred: false, rewriteEnabled: true, hasRewrite: true, translationEnabled: true, hasTranslation: false)
		#expect(dot == .green)
	}

	@Test func completedTranslationIsYellow() {
		let dot = TimelineDotPolicy.dot(isUnread: true, isStarred: false, rewriteEnabled: true, hasRewrite: false, translationEnabled: true, hasTranslation: true)
		#expect(dot == .yellow)
	}

	@Test func rewriteOutranksTranslation() {
		let dot = TimelineDotPolicy.dot(isUnread: true, isStarred: false, rewriteEnabled: true, hasRewrite: true, translationEnabled: true, hasTranslation: true)
		#expect(dot == .green)
	}

	@Test func rewriteSwitchOffHidesACompletedRewrite() {
		let dot = TimelineDotPolicy.dot(isUnread: true, isStarred: false, rewriteEnabled: false, hasRewrite: true, translationEnabled: true, hasTranslation: false)
		#expect(dot == .blue)
	}

	@Test func translationSwitchOffHidesACompletedTranslation() {
		let dot = TimelineDotPolicy.dot(isUnread: true, isStarred: false, rewriteEnabled: true, hasRewrite: false, translationEnabled: false, hasTranslation: true)
		#expect(dot == .blue)
	}

	@Test func readRowsShowNoDot() {
		let dot = TimelineDotPolicy.dot(isUnread: false, isStarred: false, rewriteEnabled: true, hasRewrite: true, translationEnabled: true, hasTranslation: true)
		#expect(dot == .none)
	}

	@Test func starredRowsShowNoDot() {
		let dot = TimelineDotPolicy.dot(isUnread: true, isStarred: true, rewriteEnabled: true, hasRewrite: true, translationEnabled: true, hasTranslation: true)
		#expect(dot == .none)
	}
}
