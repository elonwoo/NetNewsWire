//
//  AutoWorkPolicy.swift
//  AI
//

import Foundation

/// Decides which newly downloaded articles get automatic AI work.
///
/// The policy is deliberately conservative: only recent articles are eligible,
/// and an article without a publication date is never picked up automatically.
/// Manual entry points do not consult this policy.
///
/// Chinese articles are skipped unless the feed's language override is set:
/// rewrites and translations apply to non-Chinese articles by default, and an
/// overridden feed gets both for its Chinese articles too. An article without a
/// language sample counts as non-Chinese, the conservative fallback.
public enum AutoWorkPolicy {

	/// Articles published before this window are ignored by the automatic paths.
	public static let recencyWindow: TimeInterval = 2 * 24 * 60 * 60

	/// Minimum body length, after stripping HTML and whitespace, for a rewrite.
	public static let minimumRewriteLength = 200

	/// How many body characters are inspected when detecting Chinese text.
	public static let languageSampleLength = 4000

	/// CJK characters must make up at least this share of CJK plus letters.
	public static let chineseRatioThreshold = 0.4

	public static func shouldRewrite(_ article: AIArticle, now: Date, chineseAllowed: Bool = false) -> Bool {
		guard !article.isRead else {
			return false
		}
		guard isRecent(article, now: now) else {
			return false
		}
		guard chineseAllowed || !isChinese(article) else {
			return false
		}
		return bodyLength(article) >= minimumRewriteLength
	}

	public static func shouldTranslate(_ article: AIArticle, now: Date, chineseAllowed: Bool = false) -> Bool {
		guard !article.isRead else {
			return false
		}
		guard isRecent(article, now: now) else {
			return false
		}
		return chineseAllowed || !isChinese(article)
	}
}

// MARK: - Helpers

extension AutoWorkPolicy {

	static func isRecent(_ article: AIArticle, now: Date) -> Bool {
		guard let publishedAt = article.publishedAt else {
			return false
		}
		return publishedAt >= now.addingTimeInterval(-recencyWindow)
	}

	public static func isChinese(_ article: AIArticle) -> Bool {
		let counts = languageCounts(article)
		let total = counts.cjk + counts.letters
		guard total > 0 else {
			return false
		}
		return Double(counts.cjk) / Double(total) >= chineseRatioThreshold
	}

	/// False when the title and body produce no letters at all. Such an article
	/// counts as non-Chinese so it is never blocked for lacking a sample.
	public static func hasLanguageSample(_ article: AIArticle) -> Bool {
		let counts = languageCounts(article)
		return counts.cjk + counts.letters > 0
	}

	static func languageCounts(_ article: AIArticle) -> (cjk: Int, letters: Int) {
		let sample = article.title + String(bodyText(article).prefix(languageSampleLength))
		var cjkCount = 0
		var letterCount = 0
		for scalar in sample.unicodeScalars {
			if (0x4E00...0x9FFF).contains(scalar.value) {
				cjkCount += 1
			} else if CharacterSet.letters.contains(scalar) {
				letterCount += 1
			}
		}
		return (cjkCount, letterCount)
	}

	/// Prefers the extracted text and falls back to stripping tags from the HTML.
	static func bodyText(_ article: AIArticle) -> String {
		if let text = article.contentText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return text
		}
		guard let html = article.contentHTML else {
			return ""
		}
		return strippingTags(from: html)
	}

	static func bodyLength(_ article: AIArticle) -> Int {
		bodyText(article).filter { !$0.isWhitespace }.count
	}

	static func strippingTags(from html: String) -> String {
		var result = ""
		var inTag = false
		for character in html {
			if character == "<" {
				inTag = true
			} else if character == ">" {
				inTag = false
			} else if !inTag {
				result.append(character)
			}
		}
		return decodeEntities(result)
	}

	static func decodeEntities(_ text: String) -> String {
		let replacements: [(String, String)] = [
			("&nbsp;", " "),
			("&lt;", "<"),
			("&gt;", ">"),
			("&quot;", "\""),
			("&#39;", "'"),
			("&apos;", "'"),
			("&amp;", "&")
		]
		var result = text
		for (entity, value) in replacements {
			result = result.replacingOccurrences(of: entity, with: value)
		}
		return result
	}
}
