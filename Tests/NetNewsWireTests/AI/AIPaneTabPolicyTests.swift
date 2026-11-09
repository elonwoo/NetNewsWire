//
//  AIPaneTabPolicyTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIPaneTabPolicyTests {

	@Test func bothSwitchesShowThreeTabs() {
		#expect(AIPaneTabPolicy.visibleTabs(rewriteEnabled: true, translationEnabled: true, articleAllowsAI: true) == [.rewrite, .original, .translation])
	}

	@Test func translationOnlyShowsTranslationAndOriginal() {
		#expect(AIPaneTabPolicy.visibleTabs(rewriteEnabled: false, translationEnabled: true, articleAllowsAI: true) == [.translation, .original])
	}

	@Test func rewriteOnlyShowsRewriteAndOriginal() {
		#expect(AIPaneTabPolicy.visibleTabs(rewriteEnabled: true, translationEnabled: false, articleAllowsAI: true) == [.rewrite, .original])
	}

	@Test func bothSwitchesOffShowOnlyOriginal() {
		#expect(AIPaneTabPolicy.visibleTabs(rewriteEnabled: false, translationEnabled: false, articleAllowsAI: true) == [.original])
	}

	@Test func chineseArticleWithoutOverrideShowsOnlyOriginalEvenWithCachedContent() {
		#expect(AIPaneTabPolicy.visibleTabs(rewriteEnabled: true, translationEnabled: true, articleAllowsAI: false) == [.original])
		let defaultTab = AIPaneTabPolicy.defaultTab(rewriteEnabled: true, hasRewrite: true, translationEnabled: true, hasBodyTranslation: true, articleAllowsAI: false)
		#expect(defaultTab == .original)
		let fallback = AIPaneTabPolicy.fallbackTab(rewriteEnabled: true, hasRewrite: true, articleAllowsAI: false)
		#expect(fallback == .original)
	}

	@Test func cachedRewriteOpensTheRewriteTab() {
		let tab = AIPaneTabPolicy.defaultTab(rewriteEnabled: true, hasRewrite: true, translationEnabled: true, hasBodyTranslation: true, articleAllowsAI: true)
		#expect(tab == .rewrite)
	}

	@Test func disabledRewriteNeverOpensTheRewriteTab() {
		let tab = AIPaneTabPolicy.defaultTab(rewriteEnabled: false, hasRewrite: true, translationEnabled: true, hasBodyTranslation: true, articleAllowsAI: true)
		#expect(tab == .translation)
	}

	@Test func cachedBodyTranslationOpensTheTranslationTab() {
		let tab = AIPaneTabPolicy.defaultTab(rewriteEnabled: true, hasRewrite: false, translationEnabled: true, hasBodyTranslation: true, articleAllowsAI: true)
		#expect(tab == .translation)
	}

	@Test func disabledTranslationNeverOpensTheTranslationTab() {
		let tab = AIPaneTabPolicy.defaultTab(rewriteEnabled: true, hasRewrite: false, translationEnabled: false, hasBodyTranslation: true, articleAllowsAI: true)
		#expect(tab == .original)
	}

	@Test func emptyBodyTranslationKeepsTheOriginal() {
		let tab = AIPaneTabPolicy.defaultTab(rewriteEnabled: true, hasRewrite: false, translationEnabled: true, hasBodyTranslation: false, articleAllowsAI: true)
		#expect(tab == .original)
	}

	@Test func fallbackPrefersACachedRewrite() {
		#expect(AIPaneTabPolicy.fallbackTab(rewriteEnabled: true, hasRewrite: true, articleAllowsAI: true) == .rewrite)
	}

	@Test func fallbackNeverOpensTranslation() {
		#expect(AIPaneTabPolicy.fallbackTab(rewriteEnabled: true, hasRewrite: false, articleAllowsAI: true) == .original)
		#expect(AIPaneTabPolicy.fallbackTab(rewriteEnabled: false, hasRewrite: true, articleAllowsAI: true) == .original)
		#expect(AIPaneTabPolicy.fallbackTab(rewriteEnabled: false, hasRewrite: false, articleAllowsAI: true) == .original)
	}
}
