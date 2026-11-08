//
//  HuggingFacePaperCard.swift
//  NetNewsWire
//

import Foundation
import RSParser

/// A Hugging Face daily-paper entry, structured for the paper rewrite prompt.
struct HuggingFacePaperCard: Sendable, Equatable {

	let paperID: String?
	let title: String
	let abstract: String
	let authors: [String]
	let arxivID: String?
	let arxivURL: URL?
	let paperURL: URL?
	let publishedAt: Date?

	/// Markdown-ish context that can be appended to an article before calling
	/// `AIEngine.rewrite(_:kind: .paper)`.
	func rewriteContext() -> String {
		var lines = ["标题：\(title)"]
		if let arxivURL {
			lines.append("arXiv：\(arxivURL.absoluteString)")
		}
		if let paperURL {
			lines.append("Hugging Face：\(paperURL.absoluteString)")
		}
		if !authors.isEmpty {
			lines.append("作者：\(authors.joined(separator: ", "))")
		}
		lines.append("摘要：\(abstract)")
		return lines.joined(separator: "\n")
	}
}

struct HuggingFacePaperParser: Sendable {

	private static let defaultFeedURL = "https://huggingface.co/papers"

	func parse(feedData: Data, feedURL: String = HuggingFacePaperParser.defaultFeedURL) throws -> [HuggingFacePaperCard] {
		let parserData = ParserData(url: feedURL, data: feedData)
		guard let feed = try FeedParser.parse(parserData) else {
			return []
		}
		return feed.items.compactMap { card(from: $0) }
			.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
	}

	func parse(feedXML: String, feedURL: String = HuggingFacePaperParser.defaultFeedURL) throws -> [HuggingFacePaperCard] {
		try parse(feedData: Data(feedXML.utf8), feedURL: feedURL)
	}

	/// Fallback for a Hugging Face paper page when no feed item is available.
	func parse(html: String, sourceURL: URL?) -> HuggingFacePaperCard? {
		guard let title = HTMLTextExtractor.title(fromHTML: html), !title.isEmpty else {
			return nil
		}

		let abstract = abstractText(fromHTML: html)
		guard !abstract.isEmpty else {
			return nil
		}

		let arxivURL = arxivURL(fromHTML: html)
		let paperURL = huggingFacePaperURL(fromHTML: html, sourceURL: sourceURL)
		let paperID = paperID(from: paperURL, sourceURL: sourceURL)
		let arxivID = arxivURL.flatMap { Self.arxivID(from: $0.absoluteString) }

		return HuggingFacePaperCard(
			paperID: paperID,
			title: title,
			abstract: abstract,
			authors: authors(fromHTML: html),
			arxivID: arxivID,
			arxivURL: arxivURL,
			paperURL: paperURL,
			publishedAt: nil
		)
	}
}

private extension HuggingFacePaperParser {

	func card(from item: ParsedItem) -> HuggingFacePaperCard? {
		guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
			return nil
		}

		let contentHTML = item.contentHTML ?? item.summary ?? ""
		let contentText = item.contentText ?? HTMLTextExtractor.text(fromHTML: contentHTML)
		let abstract = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !abstract.isEmpty else {
			return nil
		}

		let links = [item.url, item.externalURL].compactMap { $0.flatMap { URL(string: $0) } }
		let arxivURL = links.first { Self.isArxivURL($0) } ?? Self.arxivURL(from: abstract)
		let arxivID = arxivURL.flatMap { Self.arxivID(from: $0.absoluteString) } ?? Self.arxivID(from: abstract)
		let paperID = arxivID
		let paperURL = paperID.flatMap { URL(string: "https://huggingface.co/papers/\($0)") }

		let authors = (item.authors ?? [])
			.flatMap { author -> [String] in
				guard let name = author.name else {
					return []
				}
				return name.components(separatedBy: ",")
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
					.filter { !$0.isEmpty }
			}
			.sorted()

		return HuggingFacePaperCard(
			paperID: paperID,
			title: title,
			abstract: abstract,
			authors: authors,
			arxivID: arxivID,
			arxivURL: arxivURL,
			paperURL: paperURL,
			publishedAt: item.datePublished
		)
	}

	func abstractText(fromHTML html: String) -> String {
		let patterns = [
			"(?is)<meta\\s+[^>]*name\\s*=\\s*[\"']citation_abstract[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"']",
			"(?is)<meta\\s+[^>]*property\\s*=\\s*[\"']og:description[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"']",
			"(?is)<blockquote\\b[^>]*class\\s*=\\s*[\"'][^\"']*abstract[^\"']*[\"'][^>]*>(.*?)</blockquote\\s*>"
		]
		for pattern in patterns {
			if let capture = firstCapture(pattern: pattern, in: html) {
				let text = HTMLTextExtractor.text(fromHTML: capture)
				if !text.isEmpty {
					return text
				}
			}
		}
		return HTMLTextExtractor.text(fromHTML: html)
	}

	func authors(fromHTML html: String) -> [String] {
		let metaPattern = "(?is)<meta\\s+[^>]*name\\s*=\\s*[\"']citation_author[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"']"
		if let regex = try? NSRegularExpression(pattern: metaPattern) {
			let range = NSRange(html.startIndex..., in: html)
			let names = regex.matches(in: html, range: range).compactMap { match -> String? in
				guard let captureRange = Range(match.range(at: 1), in: html) else {
					return nil
				}
				return HTMLTextExtractor.decodeEntities(String(html[captureRange])).trimmingCharacters(in: .whitespacesAndNewlines)
			}.filter { !$0.isEmpty }
			if !names.isEmpty {
				return names
			}
		}

		let jsonPattern = "(?is)\"author\"\\s*:\\s*\\[(.*?)\\]"
		if let capture = firstCapture(pattern: jsonPattern, in: html) {
			let namePattern = "(?is)\"name\"\\s*:\\s*\"([^\"]+)\""
			if let regex = try? NSRegularExpression(pattern: namePattern) {
				let range = NSRange(capture.startIndex..., in: capture)
				let names = regex.matches(in: capture, range: range).compactMap { match -> String? in
					guard let captureRange = Range(match.range(at: 1), in: capture) else {
						return nil
					}
					return String(capture[captureRange])
				}
				if !names.isEmpty {
					return names
				}
			}
		}
		return []
	}

	func arxivURL(fromHTML html: String) -> URL? {
		guard let regex = try? NSRegularExpression(pattern: "(?i)href\\s*=\\s*[\"']([^\"']*arxiv\\.org/(?:abs|pdf)/[^\"']+)[\"']") else {
			return nil
		}
		let range = NSRange(html.startIndex..., in: html)
		guard let match = regex.firstMatch(in: html, range: range),
			  let captureRange = Range(match.range(at: 1), in: html) else {
			return nil
		}
		let value = HTMLTextExtractor.decodeEntities(String(html[captureRange]))
		return URL(string: value)
	}

	func huggingFacePaperURL(fromHTML html: String, sourceURL: URL?) -> URL? {
		if let sourceURL, sourceURL.host?.lowercased() == "huggingface.co", sourceURL.path.contains("/papers/") {
			return sourceURL
		}

		guard let regex = try? NSRegularExpression(pattern: "(?i)href\\s*=\\s*[\"']([^\"']*huggingface\\.co/papers/[^\"']+)[\"']") else {
			return nil
		}
		let range = NSRange(html.startIndex..., in: html)
		guard let match = regex.firstMatch(in: html, range: range),
			  let captureRange = Range(match.range(at: 1), in: html) else {
			return nil
		}
		let value = HTMLTextExtractor.decodeEntities(String(html[captureRange]))
		return URL(string: value)
	}

	func paperID(from paperURL: URL?, sourceURL: URL?) -> String? {
		for url in [paperURL, sourceURL].compactMap({ $0 }) {
			let components = url.pathComponents
			guard let index = components.firstIndex(of: "papers"), index + 1 < components.count else {
				continue
			}
			let identifier = components[index + 1]
			if !identifier.isEmpty {
				return identifier
			}
		}
		return nil
	}

	static func isArxivURL(_ url: URL) -> Bool {
		guard let host = url.host?.lowercased() else {
			return false
		}
		return (host == "arxiv.org" || host.hasSuffix(".arxiv.org")) && (url.path.contains("/abs/") || url.path.contains("/pdf/"))
	}

	static func arxivURL(from text: String) -> URL? {
		guard let regex = try? NSRegularExpression(pattern: "(?i)(?:https?://arxiv\\.org/(?:abs|pdf)/[^\\s<\"']+|arXiv:\\s*([0-9]{4}\\.[0-9]{4,5}))") else {
			return nil
		}
		let range = NSRange(text.startIndex..., in: text)
		guard let match = regex.firstMatch(in: text, range: range) else {
			return nil
		}
		if let captureRange = Range(match.range(at: 1), in: text), !captureRange.isEmpty {
			let identifier = String(text[captureRange])
			return URL(string: "https://arxiv.org/abs/\(identifier)")
		}
		guard let fullRange = Range(match.range(at: 0), in: text) else {
			return nil
		}
		return URL(string: String(text[fullRange]))
	}

	static func arxivID(from text: String) -> String? {
		guard let regex = try? NSRegularExpression(pattern: "([0-9]{4}\\.[0-9]{4,5})(?:v[0-9]+)?") else {
			return nil
		}
		let range = NSRange(text.startIndex..., in: text)
		guard let match = regex.firstMatch(in: text, range: range),
			  let captureRange = Range(match.range(at: 1), in: text) else {
			return nil
		}
		return String(text[captureRange])
	}

	func firstCapture(pattern: String, in string: String) -> String? {
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return nil
		}
		let range = NSRange(string.startIndex..., in: string)
		guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1,
			  let captureRange = Range(match.range(at: 1), in: string) else {
			return nil
		}
		return String(string[captureRange])
	}
}
