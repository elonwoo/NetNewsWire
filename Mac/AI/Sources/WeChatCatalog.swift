//
//  WeChatCatalog.swift
//  NetNewsWire
//

import Foundation
import RSParser

struct WeChatCatalogFeed: Sendable, Equatable, Hashable {

	let title: String
	let feedURL: URL
	let siteURL: URL?
	let category: String?

	var isWeChatFeed: Bool {
		guard let host = feedURL.host?.lowercased() else {
			return false
		}
		return host == "wechat2rss.bestblogs.dev" || host.hasSuffix(".wechat2rss.bestblogs.dev")
	}
}

struct WeChatCatalog: Sendable, Equatable {

	let title: String
	let sourceURL: URL?
	let feeds: [WeChatCatalogFeed]

	/// The subset served by the WeChat-to-RSS bridge. The OPML also contains
	/// ordinary blogs, which stay available in `feeds`.
	var weChatFeeds: [WeChatCatalogFeed] {
		feeds.filter(\.isWeChatFeed)
	}
}

enum WeChatCatalogParser {

	static func parse(opmlData: Data, sourceURL: URL?) throws -> WeChatCatalog {
		let parserData = ParserData(url: sourceURL?.absoluteString ?? "", data: opmlData)
		let document = try OPMLParser.parseOPML(with: parserData)

		var feeds: [WeChatCatalogFeed] = []
		collectFeeds(from: document, category: nil, into: &feeds)
		return WeChatCatalog(
			title: document.title ?? "微信公众号目录",
			sourceURL: sourceURL,
			feeds: feeds
		)
	}

	static func parse(opmlXML: String, sourceURL: URL? = nil) throws -> WeChatCatalog {
		try parse(opmlData: Data(opmlXML.utf8), sourceURL: sourceURL)
	}
}

private extension WeChatCatalogParser {

	static func collectFeeds(from item: OPMLItem, category: String?, into feeds: inout [WeChatCatalogFeed]) {
		let specifier = item.feedSpecifier
		if let specifier, let feedURL = URL(string: specifier.feedURL) {
			feeds.append(
				WeChatCatalogFeed(
					title: specifier.title ?? feedURL.absoluteString,
					feedURL: feedURL,
					siteURL: specifier.homePageURL.flatMap { URL(string: $0) },
					category: category
				)
			)
		}

		let childCategory: String?
		if specifier == nil {
			childCategory = item.titleFromAttributes ?? category
		} else {
			childCategory = category
		}

		for child in item.children ?? [] {
			collectFeeds(from: child, category: childCategory, into: &feeds)
		}
	}
}

/// Downloads and parses the built-in WeChat catalog.
struct WeChatCatalogLoader: Sendable {

	private let loader: any SourceHTTPLoading
	private let catalogURL: URL

	init(loader: any SourceHTTPLoading = URLSessionSourceLoader(), catalogURL: URL = SourceCatalog.weChatOPMLURL) {
		self.loader = loader
		self.catalogURL = catalogURL
	}

	func load() async throws -> WeChatCatalog {
		let response = try await loader.load(SourceHTTPRequest(url: catalogURL, headers: SourceHTTPRequest.browserHeaders))
		return try WeChatCatalogParser.parse(opmlData: response.data, sourceURL: catalogURL)
	}
}
