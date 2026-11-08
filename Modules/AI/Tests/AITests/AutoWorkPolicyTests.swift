//
//  AutoWorkPolicyTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class AutoWorkPolicyTests {

	private let now = Date(timeIntervalSince1970: 1_800_000_000)

	@Test func recentChineseLongArticleGetsRewriteOnly() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2500), publishedAt: daysAgo(6))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func chineseArticleBelowMinimumLengthIsNotRewritten() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 1999), publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func chineseArticleAtMinimumLengthIsRewritten() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2000), publishedAt: daysAgo(1))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func recentEnglishLongArticleGetsRewriteAndTranslation() {
		let article = makeArticle(title: "Hello World", body: String(repeating: "a", count: 2500), publishedAt: daysAgo(1))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func englishArticleBelowMinimumLengthIsNotRewritten() {
		let article = makeArticle(title: "Hello World", body: String(repeating: "a", count: 1999), publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func oldChineseArticleIsIgnored() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2500), publishedAt: daysAgo(8))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func oldEnglishArticleIsNotTranslated() {
		let article = makeArticle(title: "Hello World", body: String(repeating: "a", count: 2500), publishedAt: daysAgo(8))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func missingPublicationDateIsIgnored() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2500), publishedAt: nil)
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func htmlOnlyArticleUsesStrippedTextForLength() {
		let html = "<p>" + String(repeating: "中", count: 2000) + "</p>"
		let article = AIArticle(id: "article-html", title: "中文标题", contentHTML: html, contentText: nil, publishedAt: daysAgo(1))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func mixedLanguageAtThresholdCountsAsChinese() {
		// Two CJK title characters plus 998 CJK body characters against 1500
		// letters is exactly 1000 / 2500 = 0.4.
		let body = String(repeating: "中", count: 998) + String(repeating: "a", count: 1500)
		let article = makeArticle(title: "中文", body: body, publishedAt: daysAgo(1))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func mixedLanguageJustBelowThresholdCountsAsForeign() {
		let body = String(repeating: "中", count: 997) + String(repeating: "a", count: 1500)
		let article = makeArticle(title: "中文", body: body, publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.isChinese(article))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now))
	}
}

private extension AutoWorkPolicyTests {

	func daysAgo(_ days: Double) -> Date {
		now.addingTimeInterval(-days * 24 * 60 * 60)
	}

	func makeArticle(title: String, body: String, publishedAt: Date?) -> AIArticle {
		AIArticle(id: UUID().uuidString, title: title, contentText: body, publishedAt: publishedAt)
	}
}
