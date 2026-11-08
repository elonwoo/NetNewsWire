//
//  AIRewriteQualityValidator.swift
//  NetNewsWire
//

import Foundation

struct AIRewriteQuality: Sendable, Equatable {
	let ok: Bool
	let reason: String
	let sourceLength: Int
	let hanLength: Int
	let paragraphCount: Int
	let minHanLength: Int
	let minParagraphCount: Int
}

/// Rejects rewrites that are refusals, too short in Chinese, or too thin in
/// paragraphs. Thresholds follow the reference implementation: the required
/// Chinese length scales with the source, and longer sources need more
/// paragraphs.
enum AIRewriteQualityValidator {

	static func evaluate(sourceText: String, body: String) -> AIRewriteQuality {
		let plainBody = plainText(body)
		let sourceLength = signalLength(sourceText)
		let han = hanLength(body)
		let paragraphs = paragraphCount(body)
		let minHan = max(48, min(360, Int(ceil(Double(sourceLength) * 0.1))))
		let minParagraphs = sourceLength >= 2400 ? 3 : sourceLength >= 700 ? 2 : 1
		let opening = String(plainBody.prefix(220))

		if isRefusal(opening) {
			return AIRewriteQuality(
				ok: false,
				reason: AILocalization.string("The model refused to answer"),
				sourceLength: sourceLength,
				hanLength: han,
				paragraphCount: paragraphs,
				minHanLength: minHan,
				minParagraphCount: minParagraphs
			)
		}

		if han < minHan {
			return AIRewriteQuality(
				ok: false,
				reason: AILocalization.format("Chinese body is too short (%lld/%lld)", han, minHan),
				sourceLength: sourceLength,
				hanLength: han,
				paragraphCount: paragraphs,
				minHanLength: minHan,
				minParagraphCount: minParagraphs
			)
		}

		if paragraphs < minParagraphs {
			return AIRewriteQuality(
				ok: false,
				reason: AILocalization.format("Not enough body paragraphs (%lld/%lld)", paragraphs, minParagraphs),
				sourceLength: sourceLength,
				hanLength: han,
				paragraphCount: paragraphs,
				minHanLength: minHan,
				minParagraphCount: minParagraphs
			)
		}

		return AIRewriteQuality(
			ok: true,
			reason: "",
			sourceLength: sourceLength,
			hanLength: han,
			paragraphCount: paragraphs,
			minHanLength: minHan,
			minParagraphCount: minParagraphs
		)
	}

	static func plainText(_ value: String) -> String {
		var text = stripHTML(value)
		text = replacing(#"!\[[^\]\n]*\]\([^\n)]+\)"#, in: text, with: " ")
		text = replacing(#"\[([^\]\n]+)\]\([^\n)]+\)"#, in: text, with: "$1")
		text = replacing(#"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#, in: text, with: " ", options: [.caseInsensitive])
		text = replacing(#"^\s{0,3}#{1,6}\s+"#, in: text, with: "", options: [.anchorsMatchLines])
		text = replacing(#"^\s*>+\s?"#, in: text, with: "", options: [.anchorsMatchLines])
		text = replacing(#"^\s*(?:[-+*]|\d+[.)])\s+"#, in: text, with: "", options: [.anchorsMatchLines])
		text = replacing(#"[`*_~]"#, in: text, with: " ")
		return collapseWhitespace(text)
	}

	static func signalLength(_ value: String) -> Int {
		plainText(value).reduce(0) { partial, character in
			character.isLetter || character.isNumber ? partial + 1 : partial
		}
	}

	static func hanLength(_ value: String) -> Int {
		plainText(value).reduce(0) { partial, character in
			isHan(character) ? partial + 1 : partial
		}
	}

	static func paragraphCount(_ value: String) -> Int {
		let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
		let separated = normalized.replacingOccurrences(of: #"\n\s*\n"#, with: "\u{0000}", options: .regularExpression)
		var count = 0
		for block in separated.components(separatedBy: "\u{0000}") {
			let lines = block.components(separatedBy: "\n").filter { !isHeadingLine($0) }
			let joined = lines.joined(separator: " ")
			if signalLength(joined) >= 12 {
				count += 1
			}
		}
		return count
	}
}

private extension AIRewriteQualityValidator {

	static let refusalPatterns = [
		#"^(?:我\s*)?(?:很|非常)?抱歉(?:[，,。.!！]|\s|$)"#,
		#"^(?:(?:我|本模型|当前模型|该模型|系统|当前|暂时|目前)\s*)?(?:无法|不能)(?:处理|完成|提供|改写|翻译|回答|访问|浏览)"#,
		#"作为\s*(?:一个|一名)?\s*(?:AI|人工智能)(?:语言)?\s*(?:助手|模型)"#,
		#"作为\s*(?:一个|一名)?\s*(?:AI|人工智能)\s*[，,]\s*(?:我)?(?:无法|不能|不会)"#,
		#"^(?:i(?:'|’)m sorry|i (?:can(?:not|'t)|am unable to))"#
	]

	static func isRefusal(_ text: String) -> Bool {
		for pattern in refusalPatterns where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
			return true
		}
		return false
	}

	static func isHan(_ character: Character) -> Bool {
		for scalar in character.unicodeScalars {
			switch scalar.value {
			case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
				return true
			default:
				continue
			}
		}
		return false
	}

	static func isHeadingLine(_ line: String) -> Bool {
		line.range(of: #"^\s{0,3}#{1,6}(?:\s|$)"#, options: .regularExpression) != nil
	}

	static func stripHTML(_ value: String) -> String {
		var text = value
		text = replacing(#"<style[\s\S]*?</style>"#, in: text, with: " ", options: [.caseInsensitive])
		text = replacing(#"<script[\s\S]*?</script>"#, in: text, with: " ", options: [.caseInsensitive])
		text = replacing(#"<[^>]+>"#, in: text, with: " ")
		text = text.replacingOccurrences(of: "&nbsp;", with: " ")
		text = text.replacingOccurrences(of: "&amp;", with: "&")
		text = text.replacingOccurrences(of: "&lt;", with: "<")
		text = text.replacingOccurrences(of: "&gt;", with: ">")
		text = text.replacingOccurrences(of: "&quot;", with: "\"")
		text = replacing(#"&#39;|&apos;|&#x27;"#, in: text, with: "'", options: [.caseInsensitive])
		return collapseWhitespace(text)
	}

	static func collapseWhitespace(_ text: String) -> String {
		text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func replacing(_ pattern: String, in text: String, with template: String, options: NSRegularExpression.Options = []) -> String {
		guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
			return text
		}
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
	}
}
