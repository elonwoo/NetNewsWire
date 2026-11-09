//
//  AutoWorkPolicyTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class AutoWorkPolicyTests {

	private let now = Date(timeIntervalSince1970: 1_800_000_000)

	@Test func recentChineseLongArticleIsSkippedWithoutOverride() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2500), publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func recentChineseLongArticleGetsBothWhenFeedIsOverridden() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2500), publishedAt: daysAgo(1))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: true))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now, chineseAllowed: true))
	}

	@Test func chineseArticleBelowMinimumLengthIsNotRewritten() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 1999), publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func chineseArticleAtMinimumLengthIsNotRewrittenWithoutOverride() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2000), publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
	}

	@Test func recentEnglishLongArticleGetsRewriteAndTranslation() {
		let article = makeArticle(title: "Hello World", body: String(repeating: "a", count: 2500), publishedAt: daysAgo(1))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func articleOneDayOldIsInsideTheWindow() {
		let article = makeArticle(title: "Hello World", body: String(repeating: "a", count: 2500), publishedAt: daysAgo(1))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func articleThreeDaysOldIsOutsideTheWindow() {
		let article = makeArticle(title: "Hello World", body: String(repeating: "a", count: 2500), publishedAt: daysAgo(3))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func readArticleIsIgnoredByAutoWork() {
		let article = makeArticle(title: "Hello World", body: String(repeating: "a", count: 2500), publishedAt: daysAgo(1), isRead: true)
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now, chineseAllowed: true))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: true))
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

	@Test func htmlOnlyChineseArticleUsesStrippedTextAndIsSkippedWithoutOverride() {
		let html = "<p>" + String(repeating: "中", count: 2000) + "</p>"
		let article = AIArticle(id: "article-html", title: "中文标题", contentHTML: html, contentText: nil, publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: true))
	}

	@Test func mixedLanguageAtThresholdCountsAsChineseAndIsSkipped() {
		// Two CJK title characters plus 998 CJK body characters against 1500
		// letters is exactly 1000 / 2500 = 0.4.
		let body = String(repeating: "中", count: 998) + String(repeating: "a", count: 1500)
		let article = makeArticle(title: "中文", body: body, publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: true))
	}

	@Test func emptyLanguageSampleIsNotChineseAndIsNotBlocked() {
		let article = AIArticle(id: "empty", title: "", contentText: " \n ", publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.isChinese(article))
		#expect(!AutoWorkPolicy.hasLanguageSample(article))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now))
	}

	@Test func oldChineseArticleStaysSkippedEvenWithOverride() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 2500), publishedAt: daysAgo(8))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: true))
		#expect(!AutoWorkPolicy.shouldTranslate(article, now: now, chineseAllowed: true))
	}

	@Test func chineseArticleBelowMinimumLengthTranslatesOnlyWithOverride() {
		let article = makeArticle(title: "中文标题", body: String(repeating: "中", count: 1999), publishedAt: daysAgo(1))
		#expect(!AutoWorkPolicy.shouldRewrite(article, now: now, chineseAllowed: true))
		#expect(AutoWorkPolicy.shouldTranslate(article, now: now, chineseAllowed: true))
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

	func makeArticle(title: String, body: String, publishedAt: Date?, isRead: Bool = false) -> AIArticle {
		AIArticle(id: UUID().uuidString, title: title, contentText: body, publishedAt: publishedAt, isRead: isRead)
	}
}
