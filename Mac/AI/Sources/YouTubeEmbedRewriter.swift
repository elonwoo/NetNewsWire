//
//  YouTubeEmbedRewriter.swift
//  NetNewsWire
//

import Foundation

/// Replaces YouTube links in article HTML with privacy-preserving embeds.
///
/// This is source-agnostic: it runs on any article body. Existing YouTube
/// iframes are switched to `youtube-nocookie.com`, anchors and bare URLs are
/// turned into responsive iframes, and each video is embedded at most once.
enum YouTubeEmbedRewriter {

	static let noCookieHost = "www.youtube-nocookie.com"

	static func rewriteHTML(_ html: String) -> String {
		var embeddedIDs = Set<String>()
		var result = rewriteExistingIframes(html, embeddedIDs: &embeddedIDs)
		result = rewriteAnchors(result, embeddedIDs: &embeddedIDs)
		result = rewriteBareURLs(result, embeddedIDs: &embeddedIDs)
		return result
	}

	static func videoID(from urlString: String) -> String? {
		guard let url = normalizedURL(urlString) else {
			return nil
		}
		return videoID(from: url)
	}

	static func videoID(from url: URL) -> String? {
		guard let host = url.host?.lowercased() else {
			return nil
		}

		if host == "youtu.be" || host == "www.youtu.be" {
			let components = url.pathComponents.filter { $0 != "/" }
			return validID(components.first)
		}

		guard host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") else {
			return nil
		}

		if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
			.queryItems?
			.first(where: { $0.name == "v" })?
			.value {
			return validID(value)
		}

		let components = url.pathComponents.filter { $0 != "/" }
		guard components.count >= 2 else {
			return nil
		}
		let kind = components[0].lowercased()
		guard kind == "embed" || kind == "shorts" || kind == "live" || kind == "v" else {
			return nil
		}
		return validID(components[1])
	}
}

private extension YouTubeEmbedRewriter {

	struct Replacement {

		let range: NSRange
		let text: String
	}

	static func rewriteExistingIframes(_ html: String, embeddedIDs: inout Set<String>) -> String {
		let pattern = "(?is)<iframe\\b[^>]*\\bsrc\\s*=\\s*([\"'])([^\"']+)\\1[^>]*>"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return html
		}

		let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
		var replacements: [Replacement] = []

		for match in matches {
			guard let sourceRange = Range(match.range(at: 2), in: html) else {
				continue
			}
			let source = String(html[sourceRange])
			guard let identifier = videoID(from: source) else {
				continue
			}
			embeddedIDs.insert(identifier)
			replacements.append(Replacement(range: match.range(at: 2), text: embedURL(identifier)))
		}

		return applying(replacements, to: html)
	}

	static func rewriteAnchors(_ html: String, embeddedIDs: inout Set<String>) -> String {
		let pattern = "(?is)<a\\b[^>]*\\bhref\\s*=\\s*([\"'])([^\"']+)\\1[^>]*>(.*?)</a\\s*>"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return html
		}

		let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
		var replacements: [Replacement] = []

		for match in matches {
			guard let hrefRange = Range(match.range(at: 2), in: html) else {
				continue
			}
			let href = String(html[hrefRange])
			guard let identifier = videoID(from: href), !embeddedIDs.contains(identifier) else {
				continue
			}
			embeddedIDs.insert(identifier)

			let title: String
			if let innerRange = Range(match.range(at: 3), in: html) {
				title = HTMLTextExtractor.text(fromHTML: String(html[innerRange]))
			} else {
				title = ""
			}
			replacements.append(Replacement(range: match.range, text: embedHTML(identifier: identifier, title: title)))
		}

		return applying(replacements, to: html)
	}

	static func rewriteBareURLs(_ html: String, embeddedIDs: inout Set<String>) -> String {
		let pattern = "(?i)(?<![=\"'\\w])(https?://(?:www\\.)?(?:youtube\\.com|youtu\\.be|m\\.youtube\\.com|music\\.youtube\\.com)/[^\\s<\"']+)"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return html
		}

		let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
		var replacements: [Replacement] = []

		for match in matches {
			guard let urlRange = Range(match.range(at: 1), in: html) else {
				continue
			}
			var urlString = String(html[urlRange])
			var trailingCount = 0
			while let last = urlString.last, ".,;:!?)]}'\"".contains(last) {
				urlString.removeLast()
				trailingCount += 1
			}
			guard let identifier = videoID(from: urlString), !embeddedIDs.contains(identifier) else {
				continue
			}
			embeddedIDs.insert(identifier)

			let replacementRange = NSRange(location: match.range(at: 1).location, length: match.range(at: 1).length - trailingCount)
			replacements.append(Replacement(range: replacementRange, text: embedHTML(identifier: identifier, title: "YouTube video")))
		}

		return applying(replacements, to: html)
	}

	static func applying(_ replacements: [Replacement], to html: String) -> String {
		guard !replacements.isEmpty else {
			return html
		}
		let mutable = NSMutableString(string: html)
		for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
			mutable.replaceCharacters(in: replacement.range, with: replacement.text)
		}
		return mutable as String
	}

	static func embedHTML(identifier: String, title: String) -> String {
		let displayTitle = title.isEmpty ? "YouTube video" : title
		return "<div class=\"nnw-youtube-embed\"><iframe src=\"\(embedURL(identifier))\" title=\"\(escapeAttribute(displayTitle))\" loading=\"lazy\" style=\"width:100%;aspect-ratio:16/9;border:0;\" allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share\" allowfullscreen></iframe></div>"
	}

	static func embedURL(_ identifier: String) -> String {
		"https://\(noCookieHost)/embed/\(identifier)"
	}

	static func escapeAttribute(_ string: String) -> String {
		string
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}

	static func normalizedURL(_ string: String) -> URL? {
		var value = HTMLTextExtractor.decodeEntities(string).trimmingCharacters(in: .whitespacesAndNewlines)
		if value.hasPrefix("//") {
			value = "https:" + value
		}
		if !value.contains("://") {
			value = "https://" + value
		}
		return URL(string: value)
	}

	static func validID(_ value: String?) -> String? {
		guard let value, value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
			return nil
		}
		return value
	}
}
