//
//  FeedLanguageSample.swift
//  AI
//

import Foundation

/// One article observed while judging a feed's language.
public struct FeedLanguageSample: Codable, Sendable, Equatable {

	public let articleID: String
	public let publishedAt: Date?
	public let isChinese: Bool

	public init(articleID: String, publishedAt: Date?, isChinese: Bool) {
		self.articleID = articleID
		self.publishedAt = publishedAt
		self.isChinese = isChinese
	}
}

/// The cached language window for one feed.
///
/// The cache keeps the same view as `SubscriptionLanguageDetector`'s full
/// scan — the newest `sampleLimit` articles, deterministically ordered — so a
/// cached verdict matches what a rescan would decide.
public struct FeedLanguageSampleCache: Sendable, Equatable {

	public let entries: [FeedLanguageSample]

	public init(entries: [FeedLanguageSample] = []) {
		self.entries = Self.window(from: entries)
	}

	/// Folds freshly observed samples into the window. A later observation of
	/// the same article replaces the earlier one; the window is then re-sorted
	/// and truncated.
	public func merging(newEntries: [FeedLanguageSample]) -> FeedLanguageSampleCache {
		var byArticleID: [String: FeedLanguageSample] = [:]
		for entry in entries {
			byArticleID[entry.articleID] = entry
		}
		for entry in newEntries {
			byArticleID[entry.articleID] = entry
		}
		return FeedLanguageSampleCache(entries: Array(byArticleID.values))
	}

	/// An empty window is never a Chinese subscription.
	public var isChinese: Bool {
		SubscriptionLanguageDetector.isChineseSubscription(entries.map(\.isChinese))
	}

	private static func window(from entries: [FeedLanguageSample]) -> [FeedLanguageSample] {
		let sorted = entries.sorted { lhs, rhs in
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
			return lhs.articleID < rhs.articleID
		}
		return Array(sorted.prefix(SubscriptionLanguageDetector.sampleLimit))
	}
}
