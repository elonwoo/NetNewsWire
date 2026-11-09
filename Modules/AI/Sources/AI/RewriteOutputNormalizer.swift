//
//  RewriteOutputNormalizer.swift
//  AI
//

import Foundation

/// Turns raw model output into Markdown that never leaks HTML.
///
/// The model is asked for Markdown and tokens, but real responses still contain
/// complete tags, dangling tag fragments, HTML entities and missing image
/// tokens. This normalizer repairs all of those deterministically.
public enum RewriteOutputNormalizer {

	public static func normalize(_ output: String, images: [HTMLImageRef]) -> String {
		let normalized = output
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
		let pieces = splitCode(normalized)

		var restoredImages = Set<Int>()
		var restoredCaptions = Set<Int>()
		var result = ""
		var atDocumentStart = true

		for piece in pieces {
			switch piece {
			case .code(let code):
				result += code
				if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					atDocumentStart = false
				}
			case .text(let chunk):
				var text = chunk
				if atDocumentStart {
					text = stripLeadingH1(text)
					atDocumentStart = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				}
				text = stripHorizontalRules(text)
				text = processPlainText(text, images: images, restoredImages: &restoredImages, restoredCaptions: &restoredCaptions)
				result += text
			}
		}

		result = backfillMissing(images, restoredImages: restoredImages, restoredCaptions: restoredCaptions, into: result)
		return finalize(result)
	}

	// MARK: - Code protection

	private enum Piece {
		case text(String)
		case code(String)
	}

	private static func splitCode(_ text: String) -> [Piece] {
		let lines = text.components(separatedBy: "\n")
		var pieces: [Piece] = []
		var current = ""
		var fence: String?

		for (index, line) in lines.enumerated() {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			let isLast = index == lines.count - 1
			if let openFence = fence {
				current += line + (isLast ? "" : "\n")
				if trimmed.hasPrefix(openFence) {
					fence = nil
					pieces.append(.code(current))
					current = ""
				}
				continue
			}
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				if !current.isEmpty {
					pieces.append(.text(current))
					current = ""
				}
				fence = String(trimmed.prefix(3))
				current += line + (isLast ? "" : "\n")
				continue
			}
			current += line + (isLast ? "" : "\n")
		}

		if !current.isEmpty {
			pieces.append(fence == nil ? .text(current) : .code(current))
		}
		return pieces
	}

	// MARK: - Plain text pipeline

	private static func processPlainText(_ text: String, images: [HTMLImageRef], restoredImages: inout Set<Int>, restoredCaptions: inout Set<Int>) -> String {
		var working = text
		working = removeScriptAndStyle(working)
		var protected = Protections()
		working = protected.protectInlineCode(working)
		working = restoreTokens(working, images: images, restoredImages: &restoredImages, restoredCaptions: &restoredCaptions)
		working = protected.protectMarkdownLinks(working)
		working = protected.protectAutolinks(working)
		working = decodeEscapedTags(working)
		working = convertTags(working)
		return protected.restore(working)
	}

	// MARK: - Heading and rules

	private static func stripLeadingH1(_ text: String) -> String {
		var index = text.startIndex
		while index < text.endIndex, text[index].isWhitespace {
			index = text.index(after: index)
		}
		guard index < text.endIndex, text[index] == "#" else {
			return text
		}
		let next = text.index(after: index)
		guard next < text.endIndex, text[next].isWhitespace else {
			return text
		}
		var end = next
		while end < text.endIndex, text[end] != "\n" {
			end = text.index(after: end)
		}
		let remaining = text[end...].drop { $0 == "\n" }
		return String(remaining)
	}

	private static func stripHorizontalRules(_ text: String) -> String {
		let lines = text.components(separatedBy: "\n")
		let filtered = lines.filter { line in
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard trimmed.count >= 3 else {
				return true
			}
			let characters = Set(trimmed)
			return !(characters.count == 1 && (characters.contains("-") || characters.contains("*") || characters.contains("_")))
		}
		return filtered.joined(separator: "\n")
	}

	// MARK: - Tokens

	private enum TokenValue {
		case image(Int)
		case caption(Int)
	}

	private static func restoreTokens(_ text: String, images: [HTMLImageRef], restoredImages: inout Set<Int>, restoredCaptions: inout Set<Int>) -> String {
		var result = ""
		var index = text.startIndex
		while index < text.endIndex {
			if text[index] == "{", let (range, token) = parseToken(text, at: index) {
				switch token {
				case .image(let imageIndex):
					if images.indices.contains(imageIndex), !restoredImages.contains(imageIndex) {
						restoredImages.insert(imageIndex)
						result += markdownImage(images[imageIndex])
					}
				case .caption(let captionIndex):
					if images.indices.contains(captionIndex),
					   let caption = images[captionIndex].caption,
					   !caption.isEmpty,
					   !restoredCaptions.contains(captionIndex) {
						restoredCaptions.insert(captionIndex)
						result += caption
					}
				}
				index = range.upperBound
				continue
			}
			result.append(text[index])
			index = text.index(after: index)
		}
		return result
	}

	private static func parseToken(_ text: String, at start: String.Index) -> (Range<String.Index>, TokenValue)? {
		for (prefix, isImage) in [("{{img:", true), ("{{caption:", false)] {
			guard text[start...].hasPrefix(prefix) else {
				continue
			}
			var index = text.index(start, offsetBy: prefix.count)
			var digits = ""
			while index < text.endIndex, text[index].isNumber {
				digits.append(text[index])
				index = text.index(after: index)
			}
			guard !digits.isEmpty, index < text.endIndex, text[index] == "}" else {
				continue
			}
			let second = text.index(after: index)
			guard second < text.endIndex, text[second] == "}", let number = Int(digits) else {
				continue
			}
			let end = text.index(after: second)
			return (start..<end, isImage ? .image(number) : .caption(number))
		}
		return nil
	}

	private static func markdownImage(_ image: HTMLImageRef) -> String {
		let alt = image.alt.replacingOccurrences(of: "]", with: "")
		return "![\(alt)](\(escapeMarkdownURL(image.url)))"
	}

	private static func escapeMarkdownURL(_ url: String) -> String {
		url
			.replacingOccurrences(of: " ", with: "%20")
			.replacingOccurrences(of: "(", with: "%28")
			.replacingOccurrences(of: ")", with: "%29")
			.replacingOccurrences(of: "<", with: "%3C")
			.replacingOccurrences(of: ">", with: "%3E")
			.replacingOccurrences(of: "\n", with: "")
	}

	private static func backfillMissing(_ images: [HTMLImageRef], restoredImages: Set<Int>, restoredCaptions: Set<Int>, into text: String) -> String {
		var missing: [String] = []
		for (index, image) in images.enumerated() {
			if !restoredImages.contains(index) {
				missing.append(markdownImage(image))
			}
			if let caption = image.caption, !caption.isEmpty, !restoredCaptions.contains(index) {
				missing.append(caption)
			}
		}
		guard !missing.isEmpty else {
			return text
		}
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let addition = missing.joined(separator: "\n")
		return trimmed.isEmpty ? addition : trimmed + "\n\n" + addition
	}

	// MARK: - Script and style

	private static func removeScriptAndStyle(_ text: String) -> String {
		let characters = Array(text)
		var result = ""
		var index = 0
		while index < characters.count {
			guard characters[index] == "<" else {
				result.append(characters[index])
				index += 1
				continue
			}
			guard let tag = tagInfo(characters, at: index) else {
				result.append(characters[index])
				index += 1
				continue
			}
			if !tag.isClosing, !tag.isSelfClosing, tag.name == "script" || tag.name == "style" {
				if let closeStart = findClosingTag(tag.name, in: characters, from: tag.end) {
					if let gt = characters[closeStart...].firstIndex(of: ">") {
						index = gt + 1
					} else {
						index = characters.count
					}
					continue
				}
				index = characters.count
				continue
			}
			result.append(characters[index])
			index += 1
		}
		return result
	}

	private static func findClosingTag(_ name: String, in characters: [Character], from start: Int) -> Int? {
		let needle = Array("</\(name)")
		guard !needle.isEmpty, start <= characters.count - needle.count else {
			return nil
		}
		var index = start
		while index <= characters.count - needle.count {
			var matched = true
			for offset in 0..<needle.count {
				let actual = characters[index + offset]
				let expected = needle[offset]
				if actual != expected, !(actual.lowercased() == expected.lowercased() && actual.isLetter) {
					matched = false
					break
				}
			}
			if matched {
				return index
			}
			index += 1
		}
		return nil
	}

	// MARK: - Escaped tags

	private static func decodeEscapedTags(_ text: String) -> String {
		let characters = Array(text)
		var result = ""
		var index = 0
		while index < characters.count {
			if isEncodedTagStart(characters, at: index), let end = encodedTagEnd(characters, from: index) {
				let encoded = String(characters[index..<end])
				let decoded = decodeEntityTwice(encoded)
				if isTagLike(decoded) {
					result += decoded
					index = end
					continue
				}
			}
			result.append(characters[index])
			index += 1
		}
		return result
	}

	private static func isEncodedTagStart(_ characters: [Character], at index: Int) -> Bool {
		startsWith("&lt;", characters, at: index) || startsWith("&amp;lt;", characters, at: index)
	}

	private static func encodedTagEnd(_ characters: [Character], from start: Int) -> Int? {
		var index = start
		while index < characters.count {
			if startsWith("&gt;", characters, at: index) {
				return index + 4
			}
			if startsWith("&amp;gt;", characters, at: index) {
				return index + 8
			}
			if characters[index] == "<" {
				return nil
			}
			index += 1
		}
		return nil
	}

	private static func decodeEntityTwice(_ text: String) -> String {
		let once = decodeBasicEntities(text)
		return decodeBasicEntities(once)
	}

	private static func decodeBasicEntities(_ text: String) -> String {
		text
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
			.replacingOccurrences(of: "&amp;", with: "&")
	}

	private static func isTagLike(_ text: String) -> Bool {
		guard text.hasPrefix("<"), text.count >= 2 else {
			return false
		}
		let characters = Array(text)
		if characters[1] == "/" || characters[1] == "!" {
			return characters.count > 2 && (characters[2].isLetter || characters[2] == "-")
		}
		return characters[1].isLetter
	}

	// MARK: - Complete tag conversion

	private struct TagInfo {
		let name: String
		let isClosing: Bool
		let isSelfClosing: Bool
		let attributes: [String: String]
		let end: Int
	}

	private static func convertTags(_ text: String) -> String {
		let characters = Array(text)
		var result = ""
		var linkStack: [String] = []
		var index = 0

		while index < characters.count {
			guard characters[index] == "<" else {
				result.append(characters[index])
				index += 1
				continue
			}

			if startsWith("<!--", characters, at: index) {
				if let end = findSequence("-->", in: characters, from: index + 4) {
					index = end
				} else {
					break
				}
				continue
			}

			guard index + 1 < characters.count else {
				result.append("<")
				index += 1
				continue
			}
			let next = characters[index + 1]
			let looksLikeTag = next.isLetter || next == "/" || next == "!" || next == "?"
			guard looksLikeTag else {
				result.append("<")
				index += 1
				continue
			}

			guard let end = findTagEnd(characters, from: index + 1) else {
				// Dangling tag: drop up to the next `<` or the end.
				var cursor = index + 1
				while cursor < characters.count, characters[cursor] != "<" {
					cursor += 1
				}
				index = cursor
				continue
			}

			let raw = String(characters[index..<end])
			index = end
			guard let tag = parseTagInfo(raw, end: end) else {
				continue
			}
			result += convert(tag: tag, linkStack: &linkStack)
		}
		return result
	}

	private static func convert(tag: TagInfo, linkStack: inout [String]) -> String {
		switch tag.name {
		case "br":
			return "\n"
		case "p", "div", "section", "article", "header", "footer", "aside", "figure", "pre", "table", "thead", "tbody", "tfoot", "ul", "ol", "dl":
			return "\n\n"
		case "h1", "h2", "h3", "h4", "h5", "h6":
			if tag.isClosing {
				return "\n\n"
			}
			return tag.name == "h1" ? "\n## " : "\n### "
		case "li":
			return tag.isClosing ? "\n" : "\n- "
		case "blockquote":
			return tag.isClosing ? "\n" : "\n> "
		case "strong", "b":
			return "**"
		case "em", "i":
			return "*"
		case "code":
			return "`"
		case "figcaption":
			return "\n"
		case "tr":
			return tag.isClosing ? "\n" : ""
		case "td", "th":
			return tag.isClosing ? " | " : ""
		case "hr":
			return "\n\n"
		case "img":
			guard let source = tag.attributes["src"] else {
				return ""
			}
			let alt = (tag.attributes["alt"] ?? "").replacingOccurrences(of: "]", with: "")
			return "![\(alt)](\(escapeMarkdownURL(source)))"
		case "a":
			if tag.isClosing {
				let href = linkStack.popLast() ?? ""
				return href.isEmpty ? "]" : "](\(escapeMarkdownURL(href)))"
			}
			let href = tag.attributes["href"] ?? ""
			linkStack.append(href)
			return "["
		default:
			return ""
		}
	}

	private static func tagInfo(_ characters: [Character], at start: Int) -> TagInfo? {
		guard let end = findTagEnd(characters, from: start + 1) else {
			return nil
		}
		let raw = String(characters[start..<end])
		return parseTagInfo(raw, end: end)
	}

	private static func parseTagInfo(_ raw: String, end: Int) -> TagInfo? {
		let characters = Array(raw)
		guard characters.first == "<" else {
			return nil
		}
		var index = 1
		var isClosing = false
		if index < characters.count, characters[index] == "/" {
			isClosing = true
			index += 1
		}
		var name = ""
		while index < characters.count {
			let character = characters[index]
			guard character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_" else {
				break
			}
			name.append(character)
			index += 1
		}
		guard !name.isEmpty else {
			return nil
		}

		var attributes: [String: String] = [:]
		var isSelfClosing = false
		while index < characters.count {
			while index < characters.count, characters[index].isWhitespace {
				index += 1
			}
			guard index < characters.count else {
				break
			}
			if characters[index] == ">" {
				break
			}
			if characters[index] == "/" {
				isSelfClosing = true
				index += 1
				continue
			}
			var attributeName = ""
			while index < characters.count, !characters[index].isWhitespace, characters[index] != "=", characters[index] != ">", characters[index] != "/" {
				attributeName.append(characters[index])
				index += 1
			}
			guard !attributeName.isEmpty else {
				index += 1
				continue
			}
			while index < characters.count, characters[index].isWhitespace {
				index += 1
			}
			var value = ""
			if index < characters.count, characters[index] == "=" {
				index += 1
				while index < characters.count, characters[index].isWhitespace {
					index += 1
				}
				if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
					let quote = characters[index]
					index += 1
					while index < characters.count, characters[index] != quote {
						value.append(characters[index])
						index += 1
					}
					if index < characters.count, characters[index] == quote {
						index += 1
					}
				} else {
					while index < characters.count, !characters[index].isWhitespace, characters[index] != ">" {
						value.append(characters[index])
						index += 1
					}
				}
			}
			attributes[attributeName.lowercased()] = decodeBasicEntities(value)
		}
		return TagInfo(name: name.lowercased(), isClosing: isClosing, isSelfClosing: isSelfClosing, attributes: attributes, end: end)
	}

	// MARK: - Scanners

	private static func findTagEnd(_ characters: [Character], from start: Int) -> Int? {
		var index = start
		var quote: Character?
		while index < characters.count {
			let character = characters[index]
			if let currentQuote = quote {
				if character == currentQuote {
					quote = nil
				}
			} else if character == "\"" || character == "'" {
				quote = character
			} else if character == ">" {
				return index + 1
			}
			index += 1
		}
		return nil
	}

	private static func startsWith(_ prefix: String, _ characters: [Character], at index: Int) -> Bool {
		let prefixCharacters = Array(prefix)
		guard index + prefixCharacters.count <= characters.count else {
			return false
		}
		for offset in 0..<prefixCharacters.count where characters[index + offset] != prefixCharacters[offset] {
			return false
		}
		return true
	}

	private static func findSequence(_ needle: String, in characters: [Character], from start: Int) -> Int? {
		let needleCharacters = Array(needle)
		guard !needleCharacters.isEmpty, start <= characters.count - needleCharacters.count else {
			return nil
		}
		var index = start
		while index <= characters.count - needleCharacters.count {
			if startsWith(needle, characters, at: index) {
				return index + needleCharacters.count
			}
			index += 1
		}
		return nil
	}

	// MARK: - Final formatting

	private static func finalize(_ text: String) -> String {
		var lines = text.components(separatedBy: "\n")
		lines = lines.map { line in
			line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
		}
		var result = lines.joined(separator: "\n")
		result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
		return result.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: - Protected spans

	private struct Protections {

		private var stored: [String] = []

		mutating func protectInlineCode(_ text: String) -> String {
			let characters = Array(text)
			var result = ""
			var index = 0
			while index < characters.count {
				guard characters[index] == "`" else {
					result.append(characters[index])
					index += 1
					continue
				}
				var runLength = 0
				while index + runLength < characters.count, characters[index + runLength] == "`" {
					runLength += 1
				}
				let closing = findBacktickRun(characters, from: index + runLength, length: runLength)
				if let closing {
					let span = String(characters[index...closing])
					result += store(span)
					index = closing + 1
				} else {
					result.append(contentsOf: String(characters[index..<(index + runLength)]))
					index += runLength
				}
			}
			return result
		}

		mutating func protectMarkdownLinks(_ text: String) -> String {
			protect(pattern: #"!?\[[^\]\n]*\]\([^)\n]*\)"#, in: text)
		}

		mutating func protectAutolinks(_ text: String) -> String {
			protect(pattern: #"<(?:https?://|mailto:)[^>\s]+>"#, in: text)
		}

		func restore(_ text: String) -> String {
			var result = text
			for (index, value) in stored.enumerated() {
				result = result.replacingOccurrences(of: placeholder(index), with: value)
			}
			return result
		}

		private mutating func protect(pattern: String, in text: String) -> String {
			guard let regex = try? NSRegularExpression(pattern: pattern) else {
				return text
			}
			let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
			guard !matches.isEmpty else {
				return text
			}
			var result = text
			for match in matches.reversed() {
				guard let range = Range(match.range, in: result) else {
					continue
				}
				let original = String(result[range])
				result.replaceSubrange(range, with: store(original))
			}
			return result
		}

		private mutating func store(_ value: String) -> String {
			stored.append(value)
			return placeholder(stored.count - 1)
		}

		private func placeholder(_ index: Int) -> String {
			"\u{0001}\(index)\u{0001}"
		}

		private func findBacktickRun(_ characters: [Character], from start: Int, length: Int) -> Int? {
			var index = start
			while index < characters.count {
				guard characters[index] == "`" else {
					index += 1
					continue
				}
				var runLength = 0
				while index + runLength < characters.count, characters[index + runLength] == "`" {
					runLength += 1
				}
				if runLength == length {
					return index + runLength - 1
				}
				index += runLength
			}
			return nil
		}
	}
}
