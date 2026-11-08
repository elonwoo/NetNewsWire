//
//  ProductHuntFeed.swift
//  NetNewsWire
//

import Foundation
import RSParser

/// One Product Hunt item, reduced to the fields the rewrite pipeline needs.
struct ProductHuntEntry: Sendable, Equatable {

	let id: String
	let name: String
	let tagline: String
	let discussionURL: URL?
	/// The product website when the feed exposes it directly. Product Hunt’s
	/// Atom feed usually exposes a `/r/p/<id>` redirect instead.
	let websiteURL: URL?
	let publishedAt: Date?
}

struct ProductHuntFeedParser: Sendable {

	private static let defaultFeedURL = "https://www.producthunt.com/feed"

	func parse(atomData: Data, feedURL: String = ProductHuntFeedParser.defaultFeedURL) throws -> [ProductHuntEntry] {
		let parserData = ParserData(url: feedURL, data: atomData)
		guard let feed = try FeedParser.parse(parserData) else {
			return []
		}

		return feed.items.compactMap { entry(from: $0) }
			.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
	}

	func parse(atomXML: String, feedURL: String = ProductHuntFeedParser.defaultFeedURL) throws -> [ProductHuntEntry] {
		try parse(atomData: Data(atomXML.utf8), feedURL: feedURL)
	}
}

private extension ProductHuntFeedParser {

	func entry(from item: ParsedItem) -> ProductHuntEntry? {
		guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
			return nil
		}

		let contentHTML = item.contentHTML ?? item.summary ?? ""
		let contentText = item.contentText ?? HTMLTextExtractor.text(fromHTML: contentHTML)
		let links = anchorLinks(inHTML: contentHTML)

		let discussionURL = item.url.flatMap { URL(string: $0) }
			?? links.first { isProductHuntDiscussion($0.url) }?.url

		let directWebsite = links.first { isExternalWebsite($0.url) }?.url
		let redirectWebsite = links.first { isProductHuntRedirect($0.url) }?.url
		let websiteURL = directWebsite ?? redirectWebsite ?? (discussionURL.flatMap { isExternalWebsite($0) ? $0 : nil })

		return ProductHuntEntry(
			id: item.uniqueID,
			name: title,
			tagline: firstLine(from: contentText),
			discussionURL: discussionURL,
			websiteURL: websiteURL,
			publishedAt: item.datePublished
		)
	}

	func firstLine(from text: String) -> String {
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				return trimmed
			}
		}
		return ""
	}

	func anchorLinks(inHTML html: String) -> [(url: URL, text: String)] {
		guard let regex = try? NSRegularExpression(pattern: "(?is)<a\\b([^>]*)>(.*?)</a\\s*>") else {
			return []
		}
		let range = NSRange(html.startIndex..., in: html)
		return regex.matches(in: html, range: range).compactMap { match in
			guard let attributesRange = Range(match.range(at: 1), in: html),
				  let innerRange = Range(match.range(at: 2), in: html) else {
				return nil
			}
			let attributes = String(html[attributesRange])
			guard let href = HTMLTextExtractor.attributeValue(named: "href", in: attributes),
				  let url = URL(string: HTMLTextExtractor.decodeEntities(href)) else {
				return nil
			}
			let text = HTMLTextExtractor.text(fromHTML: String(html[innerRange]))
			return (url, text)
		}
	}

	func isProductHuntDiscussion(_ url: URL) -> Bool {
		guard let host = url.host?.lowercased(), isProductHuntHost(host) else {
			return false
		}
		return url.path.contains("/products/") || url.path.contains("/discussions/")
	}

	func isProductHuntRedirect(_ url: URL) -> Bool {
		guard let host = url.host?.lowercased(), isProductHuntHost(host) else {
			return false
		}
		return url.path.hasPrefix("/r/p/")
	}

	func isExternalWebsite(_ url: URL) -> Bool {
		guard let host = url.host?.lowercased(), !isProductHuntHost(host) else {
			return false
		}
		return !ProductHuntWebsiteFetcher.excludedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
	}

	func isProductHuntHost(_ host: String) -> Bool {
		host == "producthunt.com" || host.hasSuffix(".producthunt.com")
	}
}
