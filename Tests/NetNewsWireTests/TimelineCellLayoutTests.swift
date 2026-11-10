//
//  TimelineCellLayoutTests.swift
//  NetNewsWireTests
//
//  Created by Brent Simmons on 11/7/26.
//

import AppKit
import Articles
import Testing

@testable import NetNewsWire

@MainActor struct TimelineCellLayoutTests {

	@Test func feedNameAndDateAboveTitle() {
		let appearance = TimelineCellAppearance(showIcon: true, textSize: .medium, iconSize: .large, numberOfLines: 3, showsFullTitles: false, feedNameAndDateAboveTitle: true, showsLargeThumbnails: false)
		let cellData = TimelineCellData(article: makeArticle(), showFeedName: .feed, feedName: "Daring Fireball", byline: nil, iconImage: nil, showIcon: true, thumbnail: nil, showThumbnail: false)

		let layout = TimelineCellLayout(width: 400.0, height: 0.0, cellData: cellData, appearance: appearance)

		#expect(layout.dateRect.maxY <= layout.titleRect.minY)
		#expect(layout.feedNameRect.minY == layout.dateRect.minY)
	}

	@Test func chineseSubtitleAddsALineAndSitsUnderTheTitle() {
		let appearance = TimelineCellAppearance(showIcon: true, textSize: .medium, iconSize: .large, numberOfLines: 3, showsFullTitles: false, feedNameAndDateAboveTitle: false, showsLargeThumbnails: false)
		let article = makeArticle()
		let plain = TimelineCellData(article: article, showFeedName: .feed, feedName: "Daring Fireball", byline: nil, iconImage: nil, showIcon: true, thumbnail: nil, showThumbnail: false)
		let translated = TimelineCellData(article: article, showFeedName: .feed, feedName: "Daring Fireball", byline: nil, iconImage: nil, showIcon: true, thumbnail: nil, showThumbnail: false, titleZh: "苹果发布新款 MacBook Pro")

		let plainHeight = TimelineCellLayout.height(for: 400.0, cellData: plain, appearance: appearance)
		let translatedHeight = TimelineCellLayout.height(for: 400.0, cellData: translated, appearance: appearance)
		#expect(translatedHeight > plainHeight)

		let layout = TimelineCellLayout(width: 400.0, height: 0.0, cellData: translated, appearance: appearance)
		#expect(layout.subtitleRect.height > 0.0)
		#expect(layout.subtitleRect.minY >= layout.titleRect.maxY)
		#expect(layout.dateRect.minY >= layout.subtitleRect.maxY)
	}

	@Test func emptyOrWhitespaceChineseSubtitleKeepsTheHeight() {
		let appearance = TimelineCellAppearance(showIcon: true, textSize: .medium, iconSize: .large, numberOfLines: 3, showsFullTitles: false, feedNameAndDateAboveTitle: false, showsLargeThumbnails: false)
		let article = makeArticle()
		let plain = TimelineCellData(article: article, showFeedName: .feed, feedName: "Daring Fireball", byline: nil, iconImage: nil, showIcon: true, thumbnail: nil, showThumbnail: false)
		let empty = TimelineCellData(article: article, showFeedName: .feed, feedName: "Daring Fireball", byline: nil, iconImage: nil, showIcon: true, thumbnail: nil, showThumbnail: false, titleZh: "")
		let whitespace = TimelineCellData(article: article, showFeedName: .feed, feedName: "Daring Fireball", byline: nil, iconImage: nil, showIcon: true, thumbnail: nil, showThumbnail: false, titleZh: "   ")

		let plainHeight = TimelineCellLayout.height(for: 400.0, cellData: plain, appearance: appearance)
		#expect(TimelineCellLayout.height(for: 400.0, cellData: empty, appearance: appearance) == plainHeight)
		#expect(TimelineCellLayout.height(for: 400.0, cellData: whitespace, appearance: appearance) == plainHeight)
		#expect(empty.titleZh == nil)
		#expect(whitespace.titleZh == nil)
	}
}

// MARK: - Helpers

@MainActor private func makeArticle() -> Article {
	let articleID = "article1"
	let status = ArticleStatus(articleID: articleID, read: false, starred: false, dateArrived: Date())
	return Article(accountID: "account1", articleID: articleID, feedID: "feed1", uniqueID: articleID, title: "Apple Announces New MacBook Pro Models", contentHTML: "<p>The new models are available to order today.</p>", contentText: nil, markdown: nil, url: nil, externalURL: nil, summary: nil, imageURL: nil, thumbnailURL: nil, datePublished: Date(), dateModified: nil, authors: nil, attachments: nil, status: status)
}
