//
//  ProductHuntWebsiteFetcher.swift
//  NetNewsWire
//

import AI
import Foundation

/// The product website content gathered for a Product Hunt rewrite.
struct ProductHuntWebsiteContext: Sendable, Equatable {

	enum Method: String, Sendable, Equatable {

		case directHTML = "html"
		case jinaReader = "jina"
		case duckDuckGo = "duckduckgo"
	}

	let websiteURL: URL
	let method: Method
	let title: String?
	let text: String
	let productName: String

	/// Adds the website material to the article the engine will rewrite.
	/// `AIEngine.rewrite(_:kind: .productHunt)` reads `contentText`, so the
	/// supplemental context has to travel inside the article.
	func appending(to article: AIArticle) -> AIArticle {
		let context = """

		产品官网抓取资料（来源：\(method.rawValue)，网址：\(websiteURL.absoluteString)）：
		\(text)
		"""
		let contentText = (article.contentText ?? article.contentHTML ?? "") + context
		return AIArticle(
			id: article.id,
			title: article.title,
			contentHTML: article.contentHTML,
			contentText: contentText,
			url: article.url,
			feedID: article.feedID,
			publishedAt: article.publishedAt
		)
	}
}

struct ProductHuntFetchAttempt: Sendable, Equatable {

	let method: ProductHuntWebsiteContext.Method
	let errorDescription: String?
}

enum ProductHuntFetchError: Error, Sendable, Equatable {

	case websiteURLNotFound
	case insufficientContent
	case allMethodsFailed(URL, [ProductHuntFetchAttempt])
}

/// Fetches a Product Hunt product’s official website.
///
/// The website body is tried in three passes:
/// 1. Download the page and extract readable text.
/// 2. Ask Jina Reader for a markdown rendering.
/// 3. Search DuckDuckGo for pages on the same host.
///
/// The Product Hunt feed itself usually links to a `/r/p/<id>` redirect, so
/// the fetcher resolves that first, then falls back to reading the Product
/// Hunt discussion page through Jina Reader and finally to DuckDuckGo.
struct ProductHuntWebsiteFetcher: Sendable {

	static let excludedHosts: [String] = [
		"producthunt.com",
		"ph-files.imgix.net",
		"ph-avatars.imgix.net",
		"x.com",
		"twitter.com",
		"linkedin.com",
		"facebook.com",
		"instagram.com",
		"youtube.com",
		"youtu.be",
		"google.com",
		"duckduckgo.com",
		"jina.ai"
	]

	private let loader: any SourceHTTPLoading
	private let minimumTextLength: Int

	init(loader: any SourceHTTPLoading = URLSessionSourceLoader(), minimumTextLength: Int = 200) {
		self.loader = loader
		self.minimumTextLength = minimumTextLength
	}

	func fetchContext(for entry: ProductHuntEntry) async throws -> ProductHuntWebsiteContext {
		guard let websiteURL = await resolveWebsiteURL(for: entry) else {
			throw ProductHuntFetchError.websiteURLNotFound
		}
		return try await fetchContext(websiteURL: websiteURL, productName: entry.name)
	}

	func fetchContext(websiteURL: URL, productName: String) async throws -> ProductHuntWebsiteContext {
		var attempts: [ProductHuntFetchAttempt] = []

		do {
			return try await directHTMLContext(websiteURL: websiteURL, productName: productName)
		} catch {
			attempts.append(ProductHuntFetchAttempt(method: .directHTML, errorDescription: String(describing: error)))
		}

		do {
			return try await jinaReaderContext(websiteURL: websiteURL, productName: productName)
		} catch {
			attempts.append(ProductHuntFetchAttempt(method: .jinaReader, errorDescription: String(describing: error)))
		}

		do {
			return try await duckDuckGoContext(websiteURL: websiteURL, productName: productName)
		} catch {
			attempts.append(ProductHuntFetchAttempt(method: .duckDuckGo, errorDescription: String(describing: error)))
		}

		throw ProductHuntFetchError.allMethodsFailed(websiteURL, attempts)
	}
}

private extension ProductHuntWebsiteFetcher {

	func directHTMLContext(websiteURL: URL, productName: String) async throws -> ProductHuntWebsiteContext {
		let response = try await loader.load(SourceHTTPRequest(url: websiteURL, headers: SourceHTTPRequest.browserHeaders))
		let html = String(decoding: response.data, as: UTF8.self)
		let text = HTMLTextExtractor.text(fromHTML: html)
		guard text.count >= minimumTextLength else {
			throw ProductHuntFetchError.insufficientContent
		}
		return ProductHuntWebsiteContext(
			websiteURL: websiteURL,
			method: .directHTML,
			title: HTMLTextExtractor.title(fromHTML: html),
			text: text,
			productName: productName
		)
	}

	func jinaReaderContext(websiteURL: URL, productName: String) async throws -> ProductHuntWebsiteContext {
		guard let jinaURL = URL(string: "https://r.jina.ai/" + websiteURL.absoluteString) else {
			throw SourceHTTPError.invalidResponse
		}
		let response = try await loader.load(SourceHTTPRequest(url: jinaURL, headers: ["Accept": "text/plain"]))
		let text = String(decoding: response.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		guard text.count >= minimumTextLength else {
			throw ProductHuntFetchError.insufficientContent
		}
		return ProductHuntWebsiteContext(
			websiteURL: websiteURL,
			method: .jinaReader,
			title: nil,
			text: text,
			productName: productName
		)
	}

	func duckDuckGoContext(websiteURL: URL, productName: String) async throws -> ProductHuntWebsiteContext {
		let host = websiteURL.host ?? ""
		let query = host.isEmpty ? productName : "site:\(host) \(productName)"
		guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
			throw SourceHTTPError.invalidResponse
		}
		components.queryItems = [URLQueryItem(name: "q", value: query)]
		guard let searchURL = components.url else {
			throw SourceHTTPError.invalidResponse
		}

		let response = try await loader.load(SourceHTTPRequest(url: searchURL, headers: SourceHTTPRequest.browserHeaders))
		let html = String(decoding: response.data, as: UTF8.self)
		let results = DuckDuckGoResultParser.parse(html: html)
		guard !results.isEmpty else {
			throw ProductHuntFetchError.insufficientContent
		}

		let text = results.map { result in
			"\(result.title)\n\(result.snippet)\n\(result.url.absoluteString)"
		}.joined(separator: "\n\n")

		return ProductHuntWebsiteContext(
			websiteURL: websiteURL,
			method: .duckDuckGo,
			title: results.first?.title,
			text: text,
			productName: productName
		)
	}

	func resolveWebsiteURL(for entry: ProductHuntEntry) async -> URL? {
		if let websiteURL = entry.websiteURL, !Self.isExcluded(websiteURL) {
			return websiteURL
		}

		if let redirectURL = entry.websiteURL {
			if let resolved = await resolveRedirect(redirectURL), !Self.isExcluded(resolved) {
				return resolved
			}
		}

		if let pageURL = entry.discussionURL ?? entry.websiteURL,
		   let fromPage = await websiteURLFromProductHuntPage(pageURL),
		   !Self.isExcluded(fromPage) {
			return fromPage
		}

		if let discovered = await discoverWebsiteURL(productName: entry.name), !Self.isExcluded(discovered) {
			return discovered
		}

		return nil
	}

	func resolveRedirect(_ url: URL) async -> URL? {
		guard let response = try? await loader.load(SourceHTTPRequest(url: url, headers: SourceHTTPRequest.browserHeaders)) else {
			return nil
		}
		return response.finalURL
	}

	func websiteURLFromProductHuntPage(_ pageURL: URL) async -> URL? {
		guard let jinaURL = URL(string: "https://r.jina.ai/" + pageURL.absoluteString) else {
			return nil
		}
		guard let response = try? await loader.load(SourceHTTPRequest(url: jinaURL, headers: ["Accept": "text/plain"])) else {
			return nil
		}
		let markdown = String(decoding: response.data, as: UTF8.self)
		return JinaProductHuntPageParser.websiteURL(fromMarkdown: markdown)
	}

	func discoverWebsiteURL(productName: String) async -> URL? {
		guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
			return nil
		}
		components.queryItems = [URLQueryItem(name: "q", value: "\(productName) official website")]
		guard let searchURL = components.url,
			  let response = try? await loader.load(SourceHTTPRequest(url: searchURL, headers: SourceHTTPRequest.browserHeaders)) else {
			return nil
		}
		let html = String(decoding: response.data, as: UTF8.self)
		return DuckDuckGoResultParser.parse(html: html)
			.map(\.url)
			.first { !Self.isExcluded($0) }
	}

	static func isExcluded(_ url: URL) -> Bool {
		guard let host = url.host?.lowercased() else {
			return true
		}
		return excludedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
	}
}

struct DuckDuckGoResult: Sendable, Equatable {

	let title: String
	let url: URL
	let snippet: String
}

enum DuckDuckGoResultParser {

	static func parse(html: String) -> [DuckDuckGoResult] {
		guard let regex = try? NSRegularExpression(pattern: "(?is)<a\\b([^>]*)>(.*?)</a\\s*>") else {
			return []
		}

		var titles: [(url: URL, text: String)] = []
		var snippets: [String] = []
		let range = NSRange(html.startIndex..., in: html)

		for match in regex.matches(in: html, range: range) {
			guard let attributesRange = Range(match.range(at: 1), in: html),
				  let innerRange = Range(match.range(at: 2), in: html) else {
				continue
			}
			let attributes = String(html[attributesRange])
			let lowercasedAttributes = attributes.lowercased()
			let text = HTMLTextExtractor.text(fromHTML: String(html[innerRange]))

			if lowercasedAttributes.contains("result__a") {
				guard let href = HTMLTextExtractor.attributeValue(named: "href", in: attributes),
					  let url = resolvedURL(href) else {
					continue
				}
				titles.append((url, text))
			} else if lowercasedAttributes.contains("result__snippet") {
				snippets.append(text)
			}
		}

		return titles.enumerated().map { index, item in
			DuckDuckGoResult(
				title: item.text,
				url: item.url,
				snippet: index < snippets.count ? snippets[index] : ""
			)
		}
	}

	private static func resolvedURL(_ href: String) -> URL? {
		var urlString = HTMLTextExtractor.decodeEntities(href)
		if urlString.hasPrefix("//") {
			urlString = "https:" + urlString
		}
		guard let url = URL(string: urlString) else {
			return nil
		}

		if let host = url.host?.lowercased(), host.hasSuffix("duckduckgo.com"),
		   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		   let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
		   let resolved = URL(string: target) {
			return resolved
		}
		return url
	}
}

enum JinaProductHuntPageParser {

	static func websiteURL(fromMarkdown markdown: String) -> URL? {
		let preferredLabels = ["Visit website", "Website", "Visit site", "Get it"]
		for label in preferredLabels {
			if let url = link(afterLabel: label, in: markdown) {
				return url
			}
		}

		guard let regex = try? NSRegularExpression(pattern: "(?i)\\[[^\\]]+\\]\\((https?://[^)\\s]+)\\)") else {
			return nil
		}
		let range = NSRange(markdown.startIndex..., in: markdown)
		for match in regex.matches(in: markdown, range: range) {
			guard let urlRange = Range(match.range(at: 1), in: markdown),
				  let url = URL(string: String(markdown[urlRange])) else {
				continue
			}
			if !ProductHuntWebsiteFetcher.excludedHosts.contains(where: { url.host == $0 || url.host?.hasSuffix("." + $0) == true }) {
				return url
			}
		}
		return nil
	}

	private static func link(afterLabel label: String, in markdown: String) -> URL? {
		let escapedLabel = NSRegularExpression.escapedPattern(for: label)
		let pattern = "\\[\(escapedLabel)\\]\\((https?://[^)\\s]+)\\)"
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
			return nil
		}
		let range = NSRange(markdown.startIndex..., in: markdown)
		guard let match = regex.firstMatch(in: markdown, range: range),
			  let urlRange = Range(match.range(at: 1), in: markdown) else {
			return nil
		}
		return URL(string: String(markdown[urlRange]))
	}
}
