//
//  AIFullTextFetcher.swift
//  NetNewsWire
//

import AI
import Foundation

enum AIFullTextOutcome: Sendable, Equatable {
	/// The article kind is not eligible for full-text fetching. The caller keeps
	/// today's feed-based rewrite.
	case notApplicable
	case enriched(AIArticle)
	case unavailable(String)
}

protocol AIFullTextFetching: Sendable {

	nonisolated func isLikelySummary(_ article: AIArticle) async -> Bool

	nonisolated func enrichedArticle(for article: AIArticle) async -> AIFullTextOutcome
}

/// Fetches the article's web page when the feed only carried a summary and
/// replaces the body with the locally extracted main content.
struct AIFullTextFetcher: AIFullTextFetching, Sendable {

	/// Below this many non-whitespace characters a feed body is treated as a
	/// summary worth expanding.
	static let summaryCharacterLimit = 1500
	static let minimumFeedBodyCharacterCount = 5
	static let minimumExtractedCharacterCount = 600
	static let extractionGrowthFactor = 1.5
	static let extractionAbsoluteMargin = 800
	static let maximumResponseBytes = 5 * 1024 * 1024
	static let maximumReplacementRatio = 0.02
	static let minimumReplacementLimit = 20

	private let loader: any SourceHTTPLoading

	init(loader: any SourceHTTPLoading = URLSessionSourceLoader()) {
		self.loader = loader
	}

	@concurrent nonisolated func isLikelySummary(_ article: AIArticle) async -> Bool {
		Self.bodyCharacterCount(for: article) < Self.summaryCharacterLimit
	}

	@concurrent nonisolated func enrichedArticle(for article: AIArticle) async -> AIFullTextOutcome {
		guard AIRewriteKindSelector.kind(for: article) == .article else {
			return .notApplicable
		}
		guard Self.hasUsableFeedBody(article) else {
			return .unavailable("原文过短，已跳过改写")
		}
		guard let urlString = article.url else {
			return .unavailable("文章没有网页地址")
		}
		guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return .unavailable("文章网页地址无效")
		}

		do {
			let request = SourceHTTPRequest(url: url, headers: SourceHTTPRequest.browserHeaders)
			let response = try await loader.load(request)
			guard (200..<300).contains(response.statusCode) else {
				return .unavailable("网页返回状态码 \(response.statusCode)")
			}
			guard Self.isHTMLMimeType(response.mimeType) else {
				return .unavailable("网页不是 HTML")
			}
			guard response.data.count <= Self.maximumResponseBytes else {
				return .unavailable("网页超过 5 MB")
			}

			let html = String(decoding: response.data, as: UTF8.self)
			guard Self.hasAcceptableEncoding(html) else {
				return .unavailable("页面编码无法识别")
			}
			guard let extractedHTML = MainContentExtractor.mainContentHTML(from: html) else {
				return .unavailable("无法提取正文")
			}

			let feedCharacterCount = Self.bodyCharacterCount(for: article)
			let extractedText = HTMLSourceBlocks.plainText(extractedHTML)
			let extractedCharacterCount = Self.characterCount(extractedText)
			guard Self.isAcceptableExtraction(extracted: extractedCharacterCount, feed: feedCharacterCount) else {
				return .unavailable("提取结果没有比摘要更长")
			}
			guard Self.matchesFeedBody(extractedText: extractedText, article: article) else {
				return .unavailable("页面内容与摘要不一致")
			}

			let enriched = AIArticle(
				id: article.id,
				title: article.title,
				contentHTML: extractedHTML,
				contentText: nil,
				url: article.url,
				feedID: article.feedID,
				publishedAt: article.publishedAt,
				isRead: article.isRead
			)
			return .enriched(enriched)
		} catch {
			return .unavailable("获取网页失败：\(String(describing: error))")
		}
	}
}

extension AIFullTextFetcher {

	static func bodyText(for article: AIArticle) -> String {
		if let html = article.contentHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let text = HTMLSourceBlocks.plainText(html)
			if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return text
			}
		}
		return article.contentText ?? ""
	}

	static func bodyCharacterCount(for article: AIArticle) -> Int {
		characterCount(bodyText(for: article))
	}

	/// A feed body with fewer than five alphanumeric characters has no
	/// five-character shingles, so it cannot be checked against a page. Such an
	/// article has no usable teaser and is never expanded from the web.
	static func hasUsableFeedBody(_ article: AIArticle) -> Bool {
		let alphanumericCount = bodyText(for: article).reduce(0) { count, character in
			character.isLetter || character.isNumber ? count + 1 : count
		}
		return alphanumericCount >= minimumFeedBodyCharacterCount
	}
}

private extension AIFullTextFetcher {

	static func matchesFeedBody(extractedText: String, article: AIArticle) -> Bool {
		let feedShingles = shingles(in: bodyText(for: article))
		guard !feedShingles.isEmpty else {
			// There is nothing to compare against, so a page must never be
			// accepted on consistency grounds alone.
			return false
		}
		let extractedShingles = shingles(in: extractedText)
		let matches = feedShingles.intersection(extractedShingles).count
		return Double(matches) / Double(feedShingles.count) >= 0.7
	}

	/// Five-character shingles over alphanumeric-only, lowercased text.
	static func shingles(in text: String) -> Set<String> {
		let characters = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
		guard characters.count >= 5 else {
			return []
		}
		var result = Set<String>()
		for start in 0...(characters.count - 5) {
			result.insert(String(characters[start..<(start + 5)]))
		}
		return result
	}

	static func isAcceptableExtraction(extracted: Int, feed: Int) -> Bool {
		guard extracted >= minimumExtractedCharacterCount else {
			return false
		}
		guard Double(extracted) >= Double(feed) * extractionGrowthFactor else {
			return false
		}
		return extracted >= feed + extractionAbsoluteMargin
	}

	static func hasAcceptableEncoding(_ html: String) -> Bool {
		let replacements = html.reduce(0) { count, character in
			character == "\u{FFFD}" ? count + 1 : count
		}
		let ratioLimit = Int((Double(html.count) * maximumReplacementRatio).rounded(.up))
		return replacements <= max(minimumReplacementLimit, ratioLimit)
	}

	static func characterCount(_ text: String) -> Int {
		text.reduce(0) { count, character in
			character.isWhitespace ? count : count + 1
		}
	}

	static func isHTMLMimeType(_ mimeType: String?) -> Bool {
		guard let mimeType else {
			return true
		}
		let type = mimeType
			.split(separator: ";", maxSplits: 1)
			.first?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		return type == "text/html" || type == "application/xhtml+xml"
	}
}
