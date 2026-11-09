//
//  HTMLSourceBlocks.swift
//  AI
//

import Foundation

// MARK: - Public values

public struct HTMLImageRef: Sendable, Equatable {

	public let url: String
	public let alt: String
	public let caption: String?

	public init(url: String, alt: String = "", caption: String? = nil) {
		self.url = url
		self.alt = alt
		self.caption = caption
	}
}

public enum HTMLSourceBlockKind: String, Sendable {
	case text
	case media
	case code
	case table
}

public struct HTMLSourceBlock: Sendable, Equatable {

	public let index: Int
	public let tag: String
	public let kind: HTMLSourceBlockKind
	public let text: String
	public let html: String
	public let images: [HTMLImageRef]
	public let isTranslatable: Bool

	public init(index: Int, tag: String, kind: HTMLSourceBlockKind, text: String, html: String, images: [HTMLImageRef], isTranslatable: Bool) {
		self.index = index
		self.tag = tag
		self.kind = kind
		self.text = text
		self.html = html
		self.images = images
		self.isTranslatable = isTranslatable
	}
}

public struct TranslationBlockPlan: Sendable, Equatable {

	public let index: Int
	public let tag: String
	public let kind: HTMLSourceBlockKind
	public let displayText: String
	public let promptText: String
	public let templateHTML: String
	public let slotCount: Int
	public let isTranslatable: Bool
	/// Marker namespace used inside `templateHTML` and `promptText`.
	public let markerPrefix: String
	/// Source text of every slot, kept for response validation.
	public let slotTexts: [String]

	public init(index: Int, tag: String, kind: HTMLSourceBlockKind, displayText: String, promptText: String, templateHTML: String, slotCount: Int, isTranslatable: Bool, markerPrefix: String = "{{t", slotTexts: [String] = []) {
		self.index = index
		self.tag = tag
		self.kind = kind
		self.displayText = displayText
		self.promptText = promptText
		self.templateHTML = templateHTML
		self.slotCount = slotCount
		self.isTranslatable = isTranslatable
		self.markerPrefix = markerPrefix
		self.slotTexts = slotTexts
	}
}

public struct RewriteLink: Sendable, Equatable {

	public let label: String
	public let url: String

	public init(label: String, url: String) {
		self.label = label
		self.url = url
	}
}

public struct RewriteSource: Sendable, Equatable {

	public let promptText: String
	public let plainText: String
	public let images: [HTMLImageRef]
	public let links: [RewriteLink]

	public init(promptText: String, plainText: String, images: [HTMLImageRef], links: [RewriteLink]) {
		self.promptText = promptText
		self.plainText = plainText
		self.images = images
		self.links = links
	}
}

// MARK: - HTML source blocks

/// Turns article HTML into a small, deterministic list of source blocks.
///
/// This is a deliberately forgiving parser: it never throws, closes unclosed
/// tags implicitly, drops active content, and guarantees that plain text is
/// free of tags. It is shared by the rewrite and translation pipelines.
public enum HTMLSourceBlocks {

	public static func blocks(_ html: String, baseURL: URL? = nil) -> [HTMLSourceBlock] {
		guard !html.isEmpty else {
			return []
		}
		let tokens = tokenize(Array(html))
		let cleaned = dropActiveContent(tokens)
		let root = buildTree(cleaned)
		var raw: [RawBlock] = []
		appendBlocks(from: root, baseURL: baseURL, into: &raw)
		let filtered = raw.filter { block in
			if block.kind == .text {
				return !block.text.isEmpty || !block.images.isEmpty
			}
			return true
		}
		return filtered.enumerated().map { offset, block in
			HTMLSourceBlock(
				index: offset,
				tag: block.tag,
				kind: block.kind,
				text: block.text,
				html: block.html,
				images: block.images,
				isTranslatable: block.isTranslatable
			)
		}
	}

	public static func plainText(_ html: String) -> String {
		let blocks = blocks(html)
		return blocks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
	}

	/// Reparses an already-cleaned fragment. Used by the translation planner and
	/// the rewrite source builder; the fragment came from `blocks` output, so it
	/// contains no active content.
	static func fragment(_ html: String, baseURL: URL? = nil) -> HTMLSourceBlocks.ParsedNode {
		let tokens = tokenize(Array(html))
		return buildTree(tokens)
	}

	// MARK: - Entities

	private static let namedEntities: [String: String] = [
		"nbsp": " ",
		"amp": "&",
		"lt": "<",
		"gt": ">",
		"quot": "\"",
		"apos": "'",
		"eacute": "é",
		"egrave": "è",
		"agrave": "à",
		"ccedil": "ç",
		"uuml": "ü",
		"ouml": "ö",
		"auml": "ä",
		"ndash": "–",
		"mdash": "—",
		"hellip": "…",
		"copy": "©",
		"reg": "®",
		"trade": "™",
		"laquo": "«",
		"raquo": "»",
		"lsquo": "‘",
		"rsquo": "’",
		"ldquo": "“",
		"rdquo": "”",
		"middot": "·",
		"bull": "•",
		"deg": "°",
		"plusmn": "±",
		"times": "×",
		"divide": "÷",
		"frac12": "½",
		"euro": "€",
		"pound": "£",
		"yen": "¥",
		"cent": "¢",
		"zwnj": "",
		"zwj": ""
	]

	static func decodeEntities(_ text: String) -> String {
		var result = ""
		var index = text.startIndex
		while index < text.endIndex {
			guard text[index] == "&", let semicolon = text[index...].firstIndex(of: ";") else {
				result.append(text[index])
				index = text.index(after: index)
				continue
			}
			let entity = String(text[text.index(after: index)..<semicolon])
			let afterSemicolon = text.index(after: semicolon)
			if let decoded = decodeEntity(entity) {
				result += decoded
				index = afterSemicolon
			} else {
				result.append(text[index])
				index = text.index(after: index)
			}
		}
		return result
	}

	private static func decodeEntity(_ entity: String) -> String? {
		guard !entity.isEmpty else {
			return nil
		}
		if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
			let hex = String(entity.dropFirst(2))
			guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else {
				return nil
			}
			return String(scalar)
		}
		if entity.hasPrefix("#") {
			let decimal = String(entity.dropFirst())
			guard let value = UInt32(decimal, radix: 10), let scalar = UnicodeScalar(value) else {
				return nil
			}
			return String(scalar)
		}
		return namedEntities[entity.lowercased()]
	}

	// MARK: - Request safety

	/// Escapes a literal `<` when the next character would make the model see a
	/// tag. Chinese text and `a < b` stay untouched.
	static func escapeRequestText(_ text: String) -> String {
		let characters = Array(text)
		var result = ""
		result.reserveCapacity(characters.count)
		var index = 0
		while index < characters.count {
			let character = characters[index]
			if character == "<", index + 1 < characters.count {
				let next = characters[index + 1]
				if next.isLetter || next == "/" {
					result += "&lt;"
					index += 1
					continue
				}
			}
			result.append(character)
			index += 1
		}
		return result
	}

	/// Decodes only the entities the escaping above can introduce, then escapes
	/// for HTML text content.
	static func escapedHTMLText(_ text: String) -> String {
		var decoded = text
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
			.replacingOccurrences(of: "&apos;", with: "'")
			.replacingOccurrences(of: "&amp;", with: "&")
		decoded = decoded
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
		decoded = decoded.replacingOccurrences(of: "\n", with: "<br>")
		return decoded
	}

	static func collapseSpaces(_ text: String) -> String {
		let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
		return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Removes residual tags from a plain-text field. Anything that is not a
	/// complete tag is treated as text, matching the block parser.
	static func stripTags(_ text: String) -> String {
		let tokens = tokenize(Array(text))
		var result = ""
		for token in tokens {
			if case .text(let value) = token {
				result += value
			} else if case .end(let name) = token, name == "br" {
				result += "\n"
			}
		}
		return normalizeLines(decodeEntities(result))
	}

	static func normalizeLines(_ text: String) -> String {
		let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		var lines: [String] = []
		for line in normalized.components(separatedBy: "\n") {
			let collapsed = line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
			let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
			if !trimmed.isEmpty {
				lines.append(trimmed)
			}
		}
		return lines.joined(separator: "\n")
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

	static func containsHan(_ text: String) -> Bool {
		text.contains(where: isHan)
	}

	static func looksEnglish(_ text: String) -> Bool {
		var latin = 0
		var han = 0
		for character in text {
			guard character.isLetter else {
				continue
			}
			if isHan(character) {
				han += 1
			} else if character.unicodeScalars.allSatisfy({ $0.value < 128 }) {
				latin += 1
			}
		}
		return latin > 0 && latin > han
	}

	// MARK: - Tag names

	static let voidElements: Set<String> = [
		"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"
	]

	static let droppedContentElements: Set<String> = [
		"script", "style", "noscript", "template", "svg", "math", "iframe", "object", "embed", "form", "button", "textarea", "select"
	]

	static let droppedVoidElements: Set<String> = [
		"input", "link", "meta", "base"
	]

	static let containerTags: Set<String> = [
		"#root", "html", "body", "div", "section", "article", "main", "header", "footer", "aside", "nav",
		"ul", "ol", "dl", "tbody", "thead", "tfoot", "tr", "colgroup", "center"
	]

	static let leafTags: Set<String> = [
		"p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "figure", "table"
	]

	static let mediaTags: Set<String> = ["img", "hr"]

	static let textBoundaryTags: Set<String> = [
		"p", "div", "section", "article", "main", "header", "footer", "aside", "nav",
		"ul", "ol", "dl", "li", "blockquote", "pre", "figure", "table", "thead", "tbody", "tfoot", "tr",
		"h1", "h2", "h3", "h4", "h5", "h6"
	]

	static let skipSlotTags: Set<String> = ["code", "kbd", "samp", "var", "pre"]

	static let promptBoundaryTags: Set<String> = textBoundaryTags

	private static func isTagNameCharacter(_ character: Character) -> Bool {
		character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_"
	}
}

// MARK: - Tokenizer

extension HTMLSourceBlocks {

	struct ParsedAttribute {
		let name: String
		let rawValue: String?
		let value: String?
		let isAllowed: Bool
	}

	struct StartTag {
		let name: String
		let isSelfClosing: Bool
		let attributes: [ParsedAttribute]
		let startTag: String
	}

	enum Token {
		case text(String)
		case start(StartTag)
		case end(String)
		case other
	}

	final class ParsedNode {

		let id: Int
		let text: String?
		let tag: String?
		let attributes: [ParsedAttribute]
		let startTag: String
		let isVoid: Bool
		var children: [HTMLSourceBlocks.ParsedNode] = []

		init(text: String, id: Int) {
			self.id = id
			self.text = text
			self.tag = nil
			self.attributes = []
			self.startTag = ""
			self.isVoid = false
		}

		init(tag: StartTag, id: Int) {
			self.id = id
			self.text = nil
			self.tag = tag.name
			self.attributes = tag.attributes
			self.startTag = tag.startTag
			self.isVoid = tag.isSelfClosing || HTMLSourceBlocks.voidElements.contains(tag.name)
		}

		func attribute(_ names: [String]) -> String? {
			for name in names {
				if let attribute = attributes.first(where: { $0.name == name }), let value = attribute.value {
					return value
				}
			}
			return nil
		}
	}

	static func tokenize(_ characters: [Character]) -> [Token] {
		var tokens: [Token] = []
		var text = ""
		var index = 0

		func flushText() {
			if !text.isEmpty {
				tokens.append(.text(text))
				text = ""
			}
		}

		while index < characters.count {
			guard characters[index] == "<" else {
				text.append(characters[index])
				index += 1
				continue
			}

			if starts(with: "<!--", at: index, in: characters) {
				flushText()
				if let end = find("-->", from: index + 4, in: characters) {
					index = end
				} else {
					index = characters.count
				}
				continue
			}

			if index + 1 < characters.count, characters[index + 1] == "!" || characters[index + 1] == "?" {
				flushText()
				if let end = findTagEnd(from: index + 1, in: characters) {
					index = end
				} else {
					index = characters.count
				}
				continue
			}

			if index + 2 < characters.count, characters[index + 1] == "/", isTagNameCharacter(characters[index + 2]) {
				flushText()
				var cursor = index + 2
				var name = ""
				while cursor < characters.count, isTagNameCharacter(characters[cursor]) {
					name.append(characters[cursor])
					cursor += 1
				}
				if let end = findTagEnd(from: cursor, in: characters) {
					tokens.append(.end(name.lowercased()))
					index = end
				} else {
					index = characters.count
				}
				continue
			}

			if index + 1 < characters.count, characters[index + 1].isLetter {
				flushText()
				if let (tag, end) = parseStartTag(characters, from: index) {
					tokens.append(.start(tag))
					index = end
				} else {
					text.append(characters[index])
					index += 1
				}
				continue
			}

			text.append(characters[index])
			index += 1
		}

		flushText()
		return tokens
	}

	private static func starts(with prefix: String, at index: Int, in characters: [Character]) -> Bool {
		let prefixCharacters = Array(prefix)
		guard index + prefixCharacters.count <= characters.count else {
			return false
		}
		for offset in 0..<prefixCharacters.count where characters[index + offset] != prefixCharacters[offset] {
			return false
		}
		return true
	}

	private static func find(_ needle: String, from start: Int, in characters: [Character]) -> Int? {
		let needleCharacters = Array(needle)
		guard !needleCharacters.isEmpty, start <= characters.count - needleCharacters.count else {
			return nil
		}
		var index = start
		while index <= characters.count - needleCharacters.count {
			var matched = true
			for offset in 0..<needleCharacters.count where characters[index + offset] != needleCharacters[offset] {
				matched = false
				break
			}
			if matched {
				return index + needleCharacters.count
			}
			index += 1
		}
		return nil
	}

	/// Returns the index just past the closing `>`, respecting quoted attribute
	/// values. Returns nil when no `>` exists.
	private static func findTagEnd(from start: Int, in characters: [Character]) -> Int? {
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

	private static func parseStartTag(_ characters: [Character], from start: Int) -> (StartTag, Int)? {
		var index = start + 1
		var name = ""
		while index < characters.count, isTagNameCharacter(characters[index]) {
			name.append(characters[index])
			index += 1
		}
		guard !name.isEmpty else {
			return nil
		}

		var attributes: [ParsedAttribute] = []
		var sawSelfClosingSlash = false
		while index < characters.count {
			while index < characters.count, characters[index].isWhitespace {
				index += 1
			}
			guard index < characters.count else {
				return nil
			}
			if characters[index] == ">" {
				index += 1
				break
			}
			if characters[index] == "/" {
				sawSelfClosingSlash = true
				index += 1
				continue
			}

			var attributeName = ""
			while index < characters.count, !characters[index].isWhitespace, characters[index] != "=", characters[index] != ">", characters[index] != "/" {
				attributeName.append(characters[index])
				index += 1
			}
			if attributeName.isEmpty {
				index += 1
				continue
			}
			while index < characters.count, characters[index].isWhitespace {
				index += 1
			}

			var rawValue: String?
			var value: String?
			if index < characters.count, characters[index] == "=" {
				index += 1
				while index < characters.count, characters[index].isWhitespace {
					index += 1
				}
				if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
					let quote = characters[index]
					var raw = String(quote)
					var decoded = ""
					index += 1
					while index < characters.count, characters[index] != quote {
						raw.append(characters[index])
						decoded.append(characters[index])
						index += 1
					}
					if index < characters.count, characters[index] == quote {
						raw.append(quote)
						index += 1
					}
					rawValue = raw
					value = decodeEntities(decoded)
				} else {
					var unquoted = ""
					while index < characters.count, !characters[index].isWhitespace, characters[index] != ">" {
						unquoted.append(characters[index])
						index += 1
					}
					rawValue = unquoted
					value = decodeEntities(unquoted)
				}
			}

			let lowercasedName = attributeName.lowercased()
			attributes.append(ParsedAttribute(
				name: lowercasedName,
				rawValue: rawValue,
				value: value,
				isAllowed: isAllowedAttribute(lowercasedName, element: name.lowercased(), value: value)
			))
		}

		var cleaned = "<\(name.lowercased())"
		for attribute in attributes where attribute.isAllowed {
			if let raw = attribute.rawValue {
				cleaned += " \(attribute.name)=\(raw)"
			} else {
				cleaned += " \(attribute.name)"
			}
		}
		if sawSelfClosingSlash || voidElements.contains(name.lowercased()) {
			cleaned += " />"
		} else {
			cleaned += ">"
		}

		return (StartTag(name: name.lowercased(), isSelfClosing: sawSelfClosingSlash, attributes: attributes, startTag: cleaned), index)
	}

	private static let allowedAttributes: [String: Set<String>] = [
		"a": ["href", "title"],
		"img": ["src", "alt", "title", "width", "height"],
		"blockquote": ["cite"],
		"ol": ["start", "reversed", "type"],
		"li": ["value"],
		"table": ["border", "cellpadding", "cellspacing", "width"],
		"td": ["colspan", "rowspan", "align", "valign", "width", "height", "scope"],
		"th": ["colspan", "rowspan", "align", "valign", "width", "height", "scope"],
		"col": ["span", "width"],
		"colgroup": ["span", "width"]
	]

	private static func isAllowedAttribute(_ attribute: String, element: String, value: String?) -> Bool {
		if attribute.hasPrefix("on") || attribute == "style" {
			return false
		}
		if attribute == "class" {
			guard element == "pre" || element == "code", let value else {
				return false
			}
			return value.lowercased().contains("language-")
		}
		guard allowedAttributes[element]?.contains(attribute) == true else {
			return false
		}
		if attribute == "href" || attribute == "src" {
			guard let value else {
				return false
			}
			let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if lowered.hasPrefix("javascript:") || lowered.hasPrefix("vbscript:") || lowered.hasPrefix("data:") {
				return false
			}
		}
		return true
	}

	static func dropActiveContent(_ tokens: [Token]) -> [Token] {
		var result: [Token] = []
		var skipName: String?
		var skipDepth = 0

		for token in tokens {
			if let currentSkip = skipName {
				if case .start(let tag) = token, tag.name == currentSkip, !tag.isSelfClosing {
					skipDepth += 1
				} else if case .end(let name) = token, name == currentSkip {
					skipDepth -= 1
					if skipDepth == 0 {
						skipName = nil
					}
				}
				continue
			}

			switch token {
			case .start(let tag):
				if droppedVoidElements.contains(tag.name) {
					continue
				}
				if droppedContentElements.contains(tag.name), !tag.isSelfClosing {
					skipName = tag.name
					skipDepth = 1
					continue
				}
				result.append(token)
			default:
				result.append(token)
			}
		}
		return result
	}
}

// MARK: - Tree building

extension HTMLSourceBlocks {

	static func buildTree(_ tokens: [Token]) -> HTMLSourceBlocks.ParsedNode {
		let root = HTMLSourceBlocks.ParsedNode(tag: StartTag(name: "#root", isSelfClosing: false, attributes: [], startTag: ""), id: 0)
		var stack: [HTMLSourceBlocks.ParsedNode] = [root]
		var nextID = 1

		for token in tokens {
			switch token {
			case .text(let value):
				let node = HTMLSourceBlocks.ParsedNode(text: value, id: nextID)
				nextID += 1
				stack[stack.count - 1].children.append(node)
			case .start(let tag):
				applyImplicitCloses(newTag: tag.name, stack: &stack)
				let node = HTMLSourceBlocks.ParsedNode(tag: tag, id: nextID)
				nextID += 1
				stack[stack.count - 1].children.append(node)
				if !node.isVoid {
					stack.append(node)
				}
			case .end(let name):
				if let match = stack.lastIndex(where: { $0.tag == name }), match > 0 {
					stack.removeSubrange(match..<stack.count)
				}
			case .other:
				continue
			}
		}
		return root
	}

	private static func applyImplicitCloses(newTag: String, stack: inout [HTMLSourceBlocks.ParsedNode]) {
		let closes = implicitlyClosedTags(by: newTag)
		guard !closes.isEmpty else {
			return
		}
		guard let match = stack.lastIndex(where: { $0.tag.map { closes.contains($0) } ?? false }), match > 0 else {
			return
		}
		let above = stack[(match + 1)...]
		guard above.allSatisfy({ node in
			guard let tag = node.tag else {
				return true
			}
			return !containerTags.contains(tag) && !leafTags.contains(tag)
		}) else {
			return
		}
		stack.removeSubrange(match..<stack.count)
	}

	private static func implicitlyClosedTags(by newTag: String) -> Set<String> {
		var result = Set<String>()
		if textBoundaryTags.contains(newTag) {
			result.insert("p")
		}
		switch newTag {
		case "li":
			result.insert("li")
		case "td", "th":
			result.insert("td")
			result.insert("th")
		case "tr":
			result.insert("td")
			result.insert("th")
			result.insert("tr")
		case "dt", "dd":
			result.insert("dt")
			result.insert("dd")
		case "h1", "h2", "h3", "h4", "h5", "h6":
			result.formUnion(["h1", "h2", "h3", "h4", "h5", "h6"])
		default:
			break
		}
		return result
	}

	static func render(_ node: HTMLSourceBlocks.ParsedNode) -> String {
		if let text = node.text {
			return text
		}
		guard let tag = node.tag else {
			return ""
		}
		var result = node.startTag
		if node.isVoid {
			return result
		}
		for child in node.children {
			result += render(child)
		}
		result += "</\(tag)>"
		return result
	}
}

// MARK: - Block splitting

extension HTMLSourceBlocks {

	struct RawBlock {
		let tag: String
		let kind: HTMLSourceBlockKind
		let text: String
		let html: String
		let images: [HTMLImageRef]
		let isTranslatable: Bool
	}

	static func appendBlocks(from container: HTMLSourceBlocks.ParsedNode, baseURL: URL?, into blocks: inout [RawBlock]) {
		var inlineBuffer: [HTMLSourceBlocks.ParsedNode] = []

		func flush() {
			if let block = makeInlineBlock(inlineBuffer, baseURL: baseURL) {
				blocks.append(block)
			}
			inlineBuffer = []
		}

		for child in container.children {
			guard let tag = child.tag else {
				inlineBuffer.append(child)
				continue
			}
			if containerTags.contains(tag) {
				flush()
				appendBlocks(from: child, baseURL: baseURL, into: &blocks)
			} else if leafTags.contains(tag) {
				flush()
				if let block = makeLeafBlock(child, baseURL: baseURL) {
					blocks.append(block)
				}
			} else if mediaTags.contains(tag) {
				flush()
				blocks.append(makeMediaBlock(child, baseURL: baseURL))
			} else {
				inlineBuffer.append(child)
			}
		}
		flush()
	}

	private static func makeInlineBlock(_ nodes: [HTMLSourceBlocks.ParsedNode], baseURL: URL?) -> RawBlock? {
		guard !nodes.isEmpty else {
			return nil
		}
		let html = nodes.map(render).joined()
		let text = plainText(nodes: nodes)
		let images = collectImages(nodes, caption: nil, baseURL: baseURL)
		guard !text.isEmpty || !images.isEmpty else {
			return nil
		}
		let kind: HTMLSourceBlockKind = text.isEmpty ? .media : .text
		return RawBlock(tag: "#text", kind: kind, text: text, html: html, images: images, isTranslatable: !text.isEmpty)
	}

	private static func makeLeafBlock(_ node: HTMLSourceBlocks.ParsedNode, baseURL: URL?) -> RawBlock? {
		guard let tag = node.tag else {
			return nil
		}
		let html = render(node)
		let images = collectImages([node], caption: nil, baseURL: baseURL)

		switch tag {
		case "pre":
			return RawBlock(tag: tag, kind: .code, text: codeText(node), html: html, images: [], isTranslatable: false)
		case "table":
			let text = tableText(node)
			return RawBlock(tag: tag, kind: .table, text: text, html: html, images: images, isTranslatable: !text.isEmpty)
		case "figure":
			let caption = figcaptionText(node)
			if let caption, !caption.isEmpty {
				return RawBlock(tag: tag, kind: .text, text: caption, html: html, images: images, isTranslatable: true)
			}
			return RawBlock(tag: tag, kind: .media, text: images.first?.alt ?? "", html: html, images: images, isTranslatable: false)
		case "li":
			let text = listText(node)
			return RawBlock(tag: tag, kind: .text, text: text, html: html, images: images, isTranslatable: !text.isEmpty)
		default:
			let text = plainText(nodes: node.children)
			return RawBlock(tag: tag, kind: .text, text: text, html: html, images: images, isTranslatable: !text.isEmpty)
		}
	}

	private static func makeMediaBlock(_ node: HTMLSourceBlocks.ParsedNode, baseURL: URL?) -> RawBlock {
		let images = collectImages([node], caption: nil, baseURL: baseURL)
		let tag = node.tag ?? "hr"
		return RawBlock(tag: tag, kind: .media, text: "", html: render(node), images: images, isTranslatable: false)
	}
}

// MARK: - Text extraction

extension HTMLSourceBlocks {

	static func plainText(nodes: [HTMLSourceBlocks.ParsedNode]) -> String {
		var pieces = ""
		for node in nodes {
			walkPlainText(node, into: &pieces)
		}
		return normalizeLines(pieces)
	}

	private static func walkPlainText(_ node: HTMLSourceBlocks.ParsedNode, into result: inout String) {
		if let text = node.text {
			result += decodeEntities(text)
			return
		}
		guard let tag = node.tag else {
			return
		}
		if tag == "br" {
			result += " "
			return
		}
		let boundary = textBoundaryTags.contains(tag)
		if boundary {
			result += "\n"
		}
		if tag == "td" || tag == "th" {
			result += " "
		}
		for child in node.children {
			walkPlainText(child, into: &result)
		}
		if tag == "td" || tag == "th" {
			result += " "
		}
		if boundary {
			result += "\n"
		}
	}

	static func inlineText(_ nodes: [HTMLSourceBlocks.ParsedNode]) -> String {
		var result = ""
		for node in nodes {
			walkInlineText(node, into: &result)
		}
		return collapseSpaces(result)
	}

	private static func walkInlineText(_ node: HTMLSourceBlocks.ParsedNode, into result: inout String) {
		if let text = node.text {
			result += decodeEntities(text)
			return
		}
		guard let tag = node.tag else {
			return
		}
		if tag == "br" {
			result += " "
			return
		}
		if tag == "img" || tag == "hr" {
			return
		}
		for child in node.children {
			walkInlineText(child, into: &result)
		}
	}

	static func codeText(_ node: HTMLSourceBlocks.ParsedNode) -> String {
		var result = ""
		for child in node.children {
			walkInlineText(child, into: &result)
		}
		return result.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func figcaptionText(_ node: HTMLSourceBlocks.ParsedNode) -> String? {
		for child in node.children where child.tag == "figcaption" {
			let text = inlineText(child.children)
			if !text.isEmpty {
				return text
			}
		}
		return nil
	}

	static func listText(_ node: HTMLSourceBlocks.ParsedNode) -> String {
		var lines: [String] = []
		collectListLines(node, depth: 0, into: &lines)
		return lines.joined(separator: "\n")
	}

	private static func collectListLines(_ node: HTMLSourceBlocks.ParsedNode, depth: Int, into lines: inout [String]) {
		var own = ""
		for child in node.children {
			if let tag = child.tag, tag == "ul" || tag == "ol" {
				let line = collapseSpaces(own)
				if !line.isEmpty {
					lines.append(String(repeating: "  ", count: depth) + line)
					own = ""
				}
				for item in child.children where item.tag == "li" {
					collectListLines(item, depth: depth + 1, into: &lines)
				}
			} else if let tag = child.tag, tag == "li" {
				let line = collapseSpaces(own)
				if !line.isEmpty {
					lines.append(String(repeating: "  ", count: depth) + line)
					own = ""
				}
				collectListLines(child, depth: depth + 1, into: &lines)
			} else {
				own += inlineText([child])
			}
		}
		let line = collapseSpaces(own)
		if !line.isEmpty {
			lines.append(String(repeating: "  ", count: depth) + line)
		}
	}

	static func tableText(_ node: HTMLSourceBlocks.ParsedNode) -> String {
		var rows: [String] = []
		collectTableRows(node, into: &rows)
		return rows.joined(separator: "\n")
	}

	private static func collectTableRows(_ node: HTMLSourceBlocks.ParsedNode, into rows: inout [String]) {
		if node.tag == "tr" {
			var cells: [String] = []
			for child in node.children {
				if child.tag == "td" || child.tag == "th" {
					cells.append(inlineText(child.children))
				} else {
					collectTableRows(child, into: &rows)
				}
			}
			if !cells.isEmpty {
				rows.append(cells.joined(separator: " | "))
			}
			return
		}
		for child in node.children {
			collectTableRows(child, into: &rows)
		}
	}
}

// MARK: - Images

extension HTMLSourceBlocks {

	static func collectImages(_ nodes: [HTMLSourceBlocks.ParsedNode], caption: String?, baseURL: URL?) -> [HTMLImageRef] {
		var result: [HTMLImageRef] = []
		for node in nodes {
			collectImages(node, caption: caption, baseURL: baseURL, into: &result)
		}
		return result
	}

	private static func collectImages(_ node: HTMLSourceBlocks.ParsedNode, caption: String?, baseURL: URL?, into result: inout [HTMLImageRef]) {
		if node.tag == "img" {
			if let image = imageRef(node, caption: caption, baseURL: baseURL) {
				result.append(image)
			}
			return
		}
		if node.tag == "figure" {
			let figureCaption = figcaptionText(node) ?? caption
			for child in node.children {
				collectImages(child, caption: figureCaption, baseURL: baseURL, into: &result)
			}
			return
		}
		for child in node.children {
			collectImages(child, caption: caption, baseURL: baseURL, into: &result)
		}
	}

	static func imageRef(_ node: HTMLSourceBlocks.ParsedNode, caption: String?, baseURL: URL?) -> HTMLImageRef? {
		let candidates = [
			node.attribute(["src"]),
			node.attribute(["data-src"]),
			node.attribute(["data-original"]),
			srcsetURL(node.attribute(["srcset"]))
		]
		guard let resolved = candidates.compactMap({ $0 }).compactMap({ resolveURL($0, baseURL: baseURL) }).first else {
			return nil
		}
		let alt = collapseSpaces(node.attribute(["alt"]) ?? "")
		return HTMLImageRef(url: resolved, alt: alt, caption: caption)
	}

	static func srcsetURL(_ value: String?) -> String? {
		guard let value, !value.isEmpty else {
			return nil
		}
		let firstCandidate = value.components(separatedBy: ",").first ?? value
		guard let firstToken = firstCandidate.split(whereSeparator: { $0.isWhitespace }).first else {
			return nil
		}
		return String(firstToken)
	}

	static func resolveURL(_ raw: String, baseURL: URL?) -> String? {
		var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else {
			return nil
		}
		if value.hasPrefix("//") {
			value = "https:" + value
		}
		let resolved: String
		if let baseURL, let url = URL(string: value, relativeTo: baseURL), url.scheme != nil {
			resolved = url.absoluteString
		} else if let url = URL(string: value), url.scheme != nil {
			resolved = url.absoluteString
		} else {
			return nil
		}
		let lowered = resolved.lowercased()
		guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
			return nil
		}
		return resolved
	}
}

// MARK: - Translation planner

public enum TranslationBlockPlanner {

	public static func plans(from blocks: [HTMLSourceBlock]) -> [TranslationBlockPlan] {
		blocks.map { plan(for: $0) }
	}

	/// Plans for a body that arrived as plain text. Each paragraph becomes a
	/// single-slot block with no template HTML.
	public static func textPlans(from text: String, maxTokens: Int) -> ([HTMLSourceBlock], [TranslationBlockPlan]) {
		let paragraphs = plainTextParagraphs(text, maxTokens: maxTokens)
		var blocks: [HTMLSourceBlock] = []
		var plans: [TranslationBlockPlan] = []
		for (index, paragraph) in paragraphs.enumerated() {
			blocks.append(HTMLSourceBlock(index: index, tag: "#text", kind: .text, text: paragraph, html: "", images: [], isTranslatable: true))
			plans.append(TranslationBlockPlan(
				index: index,
				tag: "#text",
				kind: .text,
				displayText: paragraph,
				promptText: paragraph,
				templateHTML: "",
				slotCount: 1,
				isTranslatable: true,
				markerPrefix: "{{t",
				slotTexts: [paragraph]
			))
		}
		return (blocks, plans)
	}

	private static func plan(for block: HTMLSourceBlock) -> TranslationBlockPlan {
		switch block.kind {
		case .code:
			return TranslationBlockPlan(
				index: block.index,
				tag: block.tag,
				kind: .code,
				displayText: block.text,
				promptText: "",
				templateHTML: block.html,
				slotCount: 0,
				isTranslatable: false
			)
		case .media:
			return TranslationBlockPlan(
				index: block.index,
				tag: block.tag,
				kind: .media,
				displayText: block.images.first?.alt ?? "",
				promptText: "",
				templateHTML: block.html,
				slotCount: 0,
				isTranslatable: false
			)
		case .text, .table:
			return textPlan(for: block)
		}
	}

	private static func textPlan(for block: HTMLSourceBlock) -> TranslationBlockPlan {
		let root = HTMLSourceBlocks.fragment(block.html)
		let slots = slotNodes(in: root, kind: block.kind)
		let slotTexts = slots.map { HTMLSourceBlocks.collapseSpaces(HTMLSourceBlocks.decodeEntities($0.text ?? "")) }

		guard !slots.isEmpty else {
			return TranslationBlockPlan(
				index: block.index,
				tag: block.tag,
				kind: block.kind,
				displayText: block.text,
				promptText: "",
				templateHTML: block.html,
				slotCount: 0,
				isTranslatable: false
			)
		}

		guard let prefix = choosePrefix(for: block) else {
			return TranslationBlockPlan(
				index: block.index,
				tag: block.tag,
				kind: block.kind,
				displayText: block.text,
				promptText: block.text,
				templateHTML: "{{t0}}",
				slotCount: 1,
				isTranslatable: true,
				markerPrefix: "{{t",
				slotTexts: [block.text]
			)
		}

		var markers: [Int: String] = [:]
		for (slotIndex, slot) in slots.enumerated() {
			markers[slot.id] = "\(prefix)\(slotIndex)}}"
		}

		let template = renderTemplate(root, markers: markers)
		let prompt: String
		if slots.count == 1 {
			prompt = slotTexts[0]
		} else {
			prompt = renderPrompt(root, markers: markers, kind: block.kind)
		}

		return TranslationBlockPlan(
			index: block.index,
			tag: block.tag,
			kind: block.kind,
			displayText: block.text,
			promptText: prompt,
			templateHTML: template,
			slotCount: slots.count,
			isTranslatable: true,
			markerPrefix: prefix,
			slotTexts: slotTexts
		)
	}

	private static func choosePrefix(for block: HTMLSourceBlock) -> String? {
		for prefix in ["{{t", "{{__t", "{{T"] where !block.html.contains(prefix) {
			return prefix
		}
		return nil
	}

	private static func slotNodes(in root: HTMLSourceBlocks.ParsedNode, kind: HTMLSourceBlockKind) -> [HTMLSourceBlocks.ParsedNode] {
		var slots: [HTMLSourceBlocks.ParsedNode] = []
		func walk(_ node: HTMLSourceBlocks.ParsedNode, insideSkipped: Bool, insideCell: Bool, insideCaption: Bool) {
			if let text = node.text {
				guard !insideSkipped else {
					return
				}
				switch kind {
				case .table:
					guard insideCell else {
						return
					}
				case .text:
					if root.tag == "figure", !insideCaption {
						return
					}
				default:
					break
				}
				let decoded = HTMLSourceBlocks.decodeEntities(text)
				if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					slots.append(node)
				}
				return
			}
			guard let tag = node.tag else {
				return
			}
			let skipped = insideSkipped || HTMLSourceBlocks.skipSlotTags.contains(tag)
			let cell = insideCell || tag == "td" || tag == "th"
			let caption = insideCaption || tag == "figcaption"
			for child in node.children {
				walk(child, insideSkipped: skipped, insideCell: cell, insideCaption: caption)
			}
		}
		walk(root, insideSkipped: false, insideCell: false, insideCaption: false)
		return slots
	}

	private static func renderTemplate(_ node: HTMLSourceBlocks.ParsedNode, markers: [Int: String]) -> String {
		if let text = node.text {
			if let marker = markers[node.id] {
				return marker
			}
			return text
		}
		guard let tag = node.tag else {
			return ""
		}
		var result = node.startTag
		if node.isVoid {
			return result
		}
		for child in node.children {
			result += renderTemplate(child, markers: markers)
		}
		result += "</\(tag)>"
		return result
	}

	private static func renderPrompt(_ node: HTMLSourceBlocks.ParsedNode, markers: [Int: String], kind: HTMLSourceBlockKind) -> String {
		if kind == .table {
			var rows: [String] = []
			collectPromptRows(node, markers: markers, into: &rows)
			return HTMLSourceBlocks.normalizeLines(rows.joined(separator: "\n"))
		}
		var result = ""
		walkPrompt(node, markers: markers, into: &result)
		return HTMLSourceBlocks.normalizeLines(result)
	}

	private static func collectPromptRows(_ node: HTMLSourceBlocks.ParsedNode, markers: [Int: String], into rows: inout [String]) {
		if node.tag == "tr" {
			var cells: [String] = []
			for child in node.children {
				if child.tag == "td" || child.tag == "th" {
					var cell = ""
					for grandchild in child.children {
						walkPrompt(grandchild, markers: markers, into: &cell)
					}
					cells.append(HTMLSourceBlocks.collapseSpaces(cell))
				} else {
					collectPromptRows(child, markers: markers, into: &rows)
				}
			}
			if !cells.isEmpty {
				rows.append(cells.joined(separator: " | "))
			}
			return
		}
		for child in node.children {
			collectPromptRows(child, markers: markers, into: &rows)
		}
	}

	private static func walkPrompt(_ node: HTMLSourceBlocks.ParsedNode, markers: [Int: String], into result: inout String) {
		if let text = node.text {
			if let marker = markers[node.id] {
				result += marker
			} else {
				result += HTMLSourceBlocks.decodeEntities(text)
			}
			return
		}
		guard let tag = node.tag else {
			return
		}
		if tag == "img" || tag == "hr" {
			return
		}
		if tag == "br" {
			result += "\n"
			return
		}
		if HTMLSourceBlocks.skipSlotTags.contains(tag) {
			return
		}
		let boundary = HTMLSourceBlocks.promptBoundaryTags.contains(tag)
		if boundary {
			result += "\n"
		}
		for child in node.children {
			walkPrompt(child, markers: markers, into: &result)
		}
		if boundary {
			result += "\n"
		}
	}

	private static func plainTextParagraphs(_ text: String, maxTokens: Int) -> [String] {
		let budget = max(1000, maxTokens * 2)
		var pieces: [String] = []
		for paragraph in text.components(separatedBy: "\n\n") {
			pieces.append(contentsOf: splitOversized(paragraph, budget: budget))
		}
		let nonEmpty = pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		return nonEmpty.isEmpty ? [text] : nonEmpty
	}

	private static func splitOversized(_ text: String, budget: Int) -> [String] {
		guard text.utf8.count > budget else {
			return [text]
		}
		var pieces: [String] = []
		var current = ""
		for character in text {
			current.append(character)
			if current.utf8.count >= budget {
				pieces.append(current)
				current = ""
			}
		}
		if !current.isEmpty {
			pieces.append(current)
		}
		return pieces
	}
}

// MARK: - Rewrite source builder

public enum RewriteSourceBuilder {

	/// Selects the authoritative source: non-blank HTML, otherwise non-blank
	/// text, otherwise an empty source.
	public static func source(for article: AIArticle) -> RewriteSource {
		if let html = article.contentHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return source(html: html, baseURL: article.url.flatMap { URL(string: $0) })
		}
		return source(text: article.contentText ?? "")
	}

	public static func source(html: String, baseURL: URL?) -> RewriteSource {
		let blocks = HTMLSourceBlocks.blocks(html, baseURL: baseURL)
		let images = blocks.flatMap(\.images)
		var links: [RewriteLink] = []
		var segments: [String] = []
		var imageOffset = 0
		for block in blocks {
			let segment = serialize(block: block, imageOffset: imageOffset, baseURL: baseURL, links: &links)
			if !segment.isEmpty {
				segments.append(segment)
			}
			imageOffset += block.images.count
		}
		let plainText = blocks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
		return RewriteSource(
			promptText: segments.joined(separator: "\n\n"),
			plainText: plainText,
			images: images,
			links: links
		)
	}

	public static func source(text: String) -> RewriteSource {
		let cleaned = HTMLSourceBlocks.stripTags(text)
		guard !cleaned.isEmpty else {
			return RewriteSource(promptText: "", plainText: "", images: [], links: [])
		}
		return RewriteSource(
			promptText: escapeTokenPrefixes(cleaned),
			plainText: cleaned,
			images: [],
			links: []
		)
	}

	static func escapeTokenPrefixes(_ text: String) -> String {
		text
			.replacingOccurrences(of: "{{img:", with: "\\{\\{img:")
			.replacingOccurrences(of: "{{t", with: "\\{\\{t")
	}

	private static func serialize(block: HTMLSourceBlock, imageOffset: Int, baseURL: URL?, links: inout [RewriteLink]) -> String {
		switch block.kind {
		case .code:
			let language = languageClass(in: block.html) ?? ""
			return "```\(language)\n\(block.text)\n```"
		case .table:
			let root = HTMLSourceBlocks.fragment(block.html, baseURL: baseURL)
			var counter = imageOffset
			return serializeTable(root, imageCounter: &counter, baseURL: baseURL, links: &links)
		case .media:
			var counter = imageOffset
			var lines: [String] = []
			for _ in block.images {
				lines.append("{{img:\(counter)}}")
				counter += 1
			}
			return lines.joined(separator: "\n")
		case .text:
			let root = HTMLSourceBlocks.fragment(block.html, baseURL: baseURL)
			var counter = imageOffset
			if let figure = root.children.first(where: { $0.tag == "figure" }) {
				return serializeFigure(figure, imageCounter: &counter, baseURL: baseURL, links: &links)
			}
			if let list = root.children.first(where: { $0.tag == "li" }) {
				return serializeList(list, depth: 0, imageCounter: &counter, baseURL: baseURL, links: &links)
			}
			var result = ""
			for child in root.children {
				result += inlineMarkdown(child, imageCounter: &counter, baseURL: baseURL, links: &links)
			}
			return HTMLSourceBlocks.normalizeLines(result)
		}
	}

	private static func serializeFigure(_ figure: HTMLSourceBlocks.ParsedNode, imageCounter: inout Int, baseURL: URL?, links: inout [RewriteLink]) -> String {
		var imageIndices: [Int] = []
		var probe = imageCounter
		collectImageIndices(figure, imageCounter: &probe, into: &imageIndices)
		let firstImageIndex = imageIndices.first

		var lines: [String] = []
		var inline = ""
		for child in figure.children {
			if child.tag == "figcaption" {
				let text = HTMLSourceBlocks.inlineText(child.children)
				if let firstImageIndex {
					lines.append(inline)
					inline = ""
					lines.append("{{caption:\(firstImageIndex)}}")
				} else if !text.isEmpty {
					inline += text
				}
			} else if child.tag == "img" {
				inline += "{{img:\(imageCounter)}}"
				imageCounter += 1
			} else {
				inline += inlineMarkdown(child, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
			}
		}
		lines.append(inline)
		return HTMLSourceBlocks.normalizeLines(lines.joined(separator: "\n"))
	}

	private static func collectImageIndices(_ node: HTMLSourceBlocks.ParsedNode, imageCounter: inout Int, into indices: inout [Int]) {
		if node.tag == "img" {
			indices.append(imageCounter)
			imageCounter += 1
			return
		}
		for child in node.children {
			collectImageIndices(child, imageCounter: &imageCounter, into: &indices)
		}
	}

	private static func serializeList(_ list: HTMLSourceBlocks.ParsedNode, depth: Int, imageCounter: inout Int, baseURL: URL?, links: inout [RewriteLink]) -> String {
		var lines: [String] = []
		var own = ""
		for child in list.children {
			if let tag = child.tag, tag == "ul" || tag == "ol" {
				let line = HTMLSourceBlocks.collapseSpaces(own)
				if !line.isEmpty {
					lines.append(String(repeating: "  ", count: depth) + "- " + line)
					own = ""
				}
				for item in child.children where item.tag == "li" {
					let nested = serializeList(item, depth: depth + 1, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
					if !nested.isEmpty {
						lines.append(nested)
					}
				}
			} else if let tag = child.tag, tag == "li" {
				let line = HTMLSourceBlocks.collapseSpaces(own)
				if !line.isEmpty {
					lines.append(String(repeating: "  ", count: depth) + "- " + line)
					own = ""
				}
				let nested = serializeList(child, depth: depth + 1, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
				if !nested.isEmpty {
					lines.append(nested)
				}
			} else {
				own += inlineMarkdown(child, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
			}
		}
		let line = HTMLSourceBlocks.collapseSpaces(own)
		if !line.isEmpty {
			lines.append(String(repeating: "  ", count: depth) + "- " + line)
		}
		return lines.joined(separator: "\n")
	}

	private static func serializeTable(_ node: HTMLSourceBlocks.ParsedNode, imageCounter: inout Int, baseURL: URL?, links: inout [RewriteLink]) -> String {
		var rows: [String] = []
		collectTableMarkdown(node, imageCounter: &imageCounter, baseURL: baseURL, links: &links, into: &rows)
		return rows.joined(separator: "\n")
	}

	private static func collectTableMarkdown(_ node: HTMLSourceBlocks.ParsedNode, imageCounter: inout Int, baseURL: URL?, links: inout [RewriteLink], into rows: inout [String]) {
		if node.tag == "tr" {
			var cells: [String] = []
			for child in node.children {
				if child.tag == "td" || child.tag == "th" {
					var cell = ""
					for grandchild in child.children {
						cell += inlineMarkdown(grandchild, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
					}
					cells.append(HTMLSourceBlocks.collapseSpaces(cell))
				} else {
					collectTableMarkdown(child, imageCounter: &imageCounter, baseURL: baseURL, links: &links, into: &rows)
				}
			}
			if !cells.isEmpty {
				rows.append(cells.joined(separator: " | "))
			}
			return
		}
		for child in node.children {
			collectTableMarkdown(child, imageCounter: &imageCounter, baseURL: baseURL, links: &links, into: &rows)
		}
	}

	private static func inlineMarkdown(_ node: HTMLSourceBlocks.ParsedNode, imageCounter: inout Int, baseURL: URL?, links: inout [RewriteLink]) -> String {
		if let text = node.text {
			return escapeTokenPrefixes(HTMLSourceBlocks.decodeEntities(text))
		}
		guard let tag = node.tag else {
			return ""
		}
		switch tag {
		case "br":
			return "\n"
		case "img":
			let token = "{{img:\(imageCounter)}}"
			imageCounter += 1
			return token
		case "hr":
			return ""
		case "a":
			var label = ""
			for child in node.children {
				label += inlineMarkdown(child, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
			}
			label = HTMLSourceBlocks.collapseSpaces(label)
			guard let href = node.attribute(["href"]),
				  let resolved = HTMLSourceBlocks.resolveURL(href, baseURL: baseURL) else {
				return label
			}
			links.append(RewriteLink(label: label, url: resolved))
			return "[\(label)](\(resolved))"
		case "strong", "b":
			return "**" + childMarkdown(node, imageCounter: &imageCounter, baseURL: baseURL, links: &links) + "**"
		case "em", "i":
			return "*" + childMarkdown(node, imageCounter: &imageCounter, baseURL: baseURL, links: &links) + "*"
		case "code":
			return "`" + childMarkdown(node, imageCounter: &imageCounter, baseURL: baseURL, links: &links) + "`"
		default:
			return childMarkdown(node, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
		}
	}

	private static func childMarkdown(_ node: HTMLSourceBlocks.ParsedNode, imageCounter: inout Int, baseURL: URL?, links: inout [RewriteLink]) -> String {
		var result = ""
		for child in node.children {
			result += inlineMarkdown(child, imageCounter: &imageCounter, baseURL: baseURL, links: &links)
		}
		return result
	}

	private static func languageClass(in html: String) -> String? {
		guard let range = html.range(of: "language-") else {
			return nil
		}
		let rest = html[range.upperBound...]
		let language = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
		return language.isEmpty ? nil : String(language)
	}
}
