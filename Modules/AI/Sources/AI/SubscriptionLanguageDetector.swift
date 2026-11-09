//
//  SubscriptionLanguageDetector.swift
//  AI
//

import Foundation

/// Decides whether a feed publishes mostly Chinese articles.
///
/// The detector is a pure function: the app layer supplies the recent articles
/// (newest first) and the per-article language flags. Empty samples count as
/// non-Chinese in the denominator, and a feed with no articles is never judged.
public enum SubscriptionLanguageDetector {

	/// How many recent articles are inspected.
	public static let sampleLimit = 20

	/// Chinese articles must make up at least this share of the sample.
	public static let chineseShareThreshold = 0.6

	/// Returns the newest `limit` articles. Articles without a publication date
	/// sort last; ties fall back to the article ID so the order is deterministic.
	public static func recentSample(from articles: [AIArticle], limit: Int = sampleLimit) -> [AIArticle] {
		guard limit > 0 else {
			return []
		}
		let sorted = articles.sorted { lhs, rhs in
			switch (lhs.publishedAt, rhs.publishedAt) {
			case let (left?, right?):
				if left != right {
					return left > right
				}
			case (_?, nil):
				return true
			case (nil, _?):
				return false
			case (nil, nil):
				break
			}
			return lhs.id < rhs.id
		}
		return Array(sorted.prefix(limit))
	}

	/// `chineseSamples` holds one flag per sampled article. An empty list means
	/// there was nothing to judge, which is never a Chinese subscription.
	public static func isChineseSubscription(_ chineseSamples: [Bool]) -> Bool {
		guard !chineseSamples.isEmpty else {
			return false
		}
		let chineseCount = chineseSamples.filter { $0 }.count
		return Double(chineseCount) / Double(chineseSamples.count) >= chineseShareThreshold
	}
}
