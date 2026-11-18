//
//  FeedLanguageSampleCacheTests.swift
//  AITests
//

import Foundation
import Testing

@testable import AI

@Suite struct FeedLanguageSampleCacheTests {

	private func sample(_ id: String, daysAgo: Double?, chinese: Bool) -> FeedLanguageSample {
		let publishedAt = daysAgo.map { Date(timeIntervalSince1970: 1_700_000_000 - $0 * 86_400) }
		return FeedLanguageSample(articleID: id, publishedAt: publishedAt, isChinese: chinese)
	}

	@Test func mergingKeepsTheNewestEntryPerArticle() {
		let cached = FeedLanguageSampleCache(entries: [sample("a", daysAgo: 3, chinese: false)])
		let merged = cached.merging(newEntries: [sample("a", daysAgo: 1, chinese: true)])

		#expect(merged.entries.count == 1)
		#expect(merged.entries.first?.isChinese == true)
	}

	@Test func mergingSortsNewestFirstAndDropsUndatedEntriesLast() {
		let merged = FeedLanguageSampleCache().merging(newEntries: [
			sample("undated", daysAgo: nil, chinese: false),
			sample("old", daysAgo: 5, chinese: false),
			sample("new", daysAgo: 1, chinese: true)
		])

		#expect(merged.entries.map(\.articleID) == ["new", "old", "undated"])
	}

	@Test func mergingTruncatesToTheDetectorSampleLimit() {
		let many = (0..<40).map { sample("article-\($0)", daysAgo: Double($0), chinese: $0 < 12) }
		let cache = FeedLanguageSampleCache(entries: many)

		#expect(cache.entries.count == SubscriptionLanguageDetector.sampleLimit)
		#expect(cache.entries.first?.articleID == "article-0")
	}

	@Test func isChineseUsesTheDetectorThresholdOnTheWindow() {
		// 13 of 20 Chinese: at or above the 0.6 threshold.
		let chineseHeavy = (0..<20).map { sample("zh-\($0)", daysAgo: Double($0), chinese: $0 < 13) }
		#expect(FeedLanguageSampleCache(entries: chineseHeavy).isChinese)

		// 11 of 20 Chinese: below the threshold.
		let englishHeavy = (0..<20).map { sample("en-\($0)", daysAgo: Double($0), chinese: $0 < 11) }
		#expect(!FeedLanguageSampleCache(entries: englishHeavy).isChinese)
	}

	@Test func emptyCacheIsNeverChinese() {
		#expect(!FeedLanguageSampleCache().isChinese)
	}
}
