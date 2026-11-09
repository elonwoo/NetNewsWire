//
//  SubscriptionLanguageDetectorTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite struct SubscriptionLanguageDetectorTests {

	private let now = Date(timeIntervalSince1970: 1_800_000_000)

	@Test func twentyArticlesAtSixtyPercentIsChinese() {
		let samples = Array(repeating: true, count: 12) + Array(repeating: false, count: 8)
		#expect(SubscriptionLanguageDetector.isChineseSubscription(samples))
	}

	@Test func twentyArticlesBelowSixtyPercentIsNotChinese() {
		let samples = Array(repeating: true, count: 11) + Array(repeating: false, count: 9)
		#expect(!SubscriptionLanguageDetector.isChineseSubscription(samples))
	}

	@Test func fewerThanTwentyArticlesUseTheActualCount() {
		#expect(SubscriptionLanguageDetector.isChineseSubscription([true, true, true, false, false]))
		#expect(!SubscriptionLanguageDetector.isChineseSubscription([true, true, false, false, false]))
	}

	@Test func emptySamplesCountAsNonChineseInTheDenominator() {
		// One Chinese article and two empty samples: 1 / 3 is below the threshold.
		#expect(!SubscriptionLanguageDetector.isChineseSubscription([true, false, false]))
	}

	@Test func fiftyPercentMixedIsNotChinese() {
		#expect(!SubscriptionLanguageDetector.isChineseSubscription([true, false]))
	}

	@Test func allChineseIsChineseAndAllEnglishIsNot() {
		#expect(SubscriptionLanguageDetector.isChineseSubscription(Array(repeating: true, count: 20)))
		#expect(!SubscriptionLanguageDetector.isChineseSubscription(Array(repeating: false, count: 20)))
	}

	@Test func noArticlesAreNeverJudged() {
		#expect(!SubscriptionLanguageDetector.isChineseSubscription([]))
	}

	@Test func recentSampleSortsByDateAndPutsMissingDatesLast() {
		let newest = AIArticle(id: "newest", title: "a", publishedAt: now)
		let older = AIArticle(id: "older", title: "b", publishedAt: now.addingTimeInterval(-3600))
		let missing = AIArticle(id: "missing", title: "c", publishedAt: nil)
		let missingTwo = AIArticle(id: "missing-two", title: "d", publishedAt: nil)

		let sample = SubscriptionLanguageDetector.recentSample(from: [missing, older, newest, missingTwo], limit: 3)

		#expect(sample.map(\.id) == ["newest", "older", "missing"])
	}

	@Test func recentSampleTruncatesToTwentyByDefault() {
		let articles = (0..<25).map { index in
			AIArticle(id: "\(index)", title: "a", publishedAt: now.addingTimeInterval(-Double(index)))
		}
		let sample = SubscriptionLanguageDetector.recentSample(from: articles)
		#expect(sample.count == 20)
		#expect(sample.first?.id == "0")
		#expect(sample.last?.id == "19")
	}
}
