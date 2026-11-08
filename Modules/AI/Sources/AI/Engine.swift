//
//  Engine.swift
//  AI
//

import CryptoKit
import Foundation

public enum RewriteKind: Sendable {
	case article
	case paper
	case productHunt
}

/// Orchestrates prompts, model calls and persistence.
///
/// The engine never truncates article bodies: rewrites and chat send the full
/// text. Translation is sent as a single request unless the estimated output
/// would exceed the configured token budget, in which case it is split into
/// blocks and every block must come back before anything is saved.
public actor AIEngine {

	private let store: AIStore
	private let client: AIClient
	private let config: AIConfig

	private static let titleBatchSize = 20

	public init(store: AIStore, client: AIClient, config: AIConfig) {
		self.store = store
		self.client = client
		self.config = config
	}

	// MARK: - Titles

	public func translateTitles(_ articles: [AIArticle]) async throws -> [String: String] {
		var translations: [String: String] = [:]
		var start = 0
		while start < articles.count {
			let end = min(start + Self.titleBatchSize, articles.count)
			let batch = Array(articles[start..<end])
			start = end

			let items = batch.map { article in
				TitleItem(id: article.id, sourceId: article.feedID ?? "", title: article.title, context: String((article.contentText ?? "").prefix(180)))
			}
			let payload = try JSONEncoder().encode(TitleRequest(items: items))
			let raw = try await client.complete(
				messages: [
					AIMessage(role: "system", content: AIPrompts.titleTranslationSystem),
					AIMessage(role: "user", content: String(decoding: payload, as: UTF8.self))
				],
				temperature: nil,
				maxTokens: nil,
				thinking: .disabled
			)
			let response = try decodeJSON(TitleResponse.self, from: raw)

			var hashes: [String: String] = [:]
			for article in batch {
				hashes[article.id] = contentHash(for: article)
			}
			let now = Date()
			for translation in response.translations {
				translations[translation.id] = translation.titleZh
				guard let hash = hashes[translation.id] else {
					continue
				}
				try await store.saveTitleTranslation(articleID: translation.id, titleZh: translation.titleZh, model: config.model, contentHash: hash, at: now)
			}
		}
		return translations
	}

	// MARK: - Body translation

	public func translateBody(_ article: AIArticle) async throws -> Translation {
		let source: SourceContent
		if let html = article.contentHTML, !html.isEmpty {
			let blocks = Self.topLevelHTMLBlocks(html)
			guard !blocks.isEmpty else {
				throw AIEngineError.emptyContent
			}
			source = SourceContent(blocks: blocks, hashSource: html)
		} else {
			let text = article.contentText ?? ""
			guard !text.isEmpty else {
				throw AIEngineError.emptyContent
			}
			source = SourceContent(blocks: Self.textBlocks(from: text, maxTokens: config.maxTokens), hashSource: text)
		}

		let groups = Self.groupBlocks(source.blocks, maxTokens: config.maxTokens)
		var responses: [Int: TranslateResponse.Block] = [:]
		var titleZh: String?
		var summaryZh: String?

		for group in groups {
			let payloadBlocks = group.map { TranslateBlock(i: $0.index, text: $0.text, html: $0.html) }
			let payload = try JSONEncoder().encode(TranslateRequest(title: article.title, summary: "", blocks: payloadBlocks))
			let raw = try await client.complete(
				messages: [
					AIMessage(role: "system", content: AIPrompts.bodyTranslationSystem),
					AIMessage(role: "user", content: String(decoding: payload, as: UTF8.self))
				],
				temperature: nil,
				maxTokens: nil,
				thinking: .disabled
			)
			let response = try decodeJSON(TranslateResponse.self, from: raw)
			for block in response.blocks {
				responses[block.i] = block
			}
			if titleZh == nil {
				titleZh = response.titleZh
			}
			if summaryZh == nil {
				summaryZh = response.summaryZh
			}
		}

		let expectedIndices = source.blocks.map(\.index)
		let missing = expectedIndices.filter { responses[$0] == nil }
		guard missing.isEmpty else {
			throw AIEngineError.incompleteTranslation(missing: missing)
		}

		var translatedBlocks: [TranslationBlock] = []
		for block in source.blocks {
			guard let response = responses[block.index] else {
				throw AIEngineError.incompleteTranslation(missing: [block.index])
			}
			translatedBlocks.append(TranslationBlock(index: block.index, source: block.text, target: response.target, targetHTML: response.targetHtml))
		}

		let now = Date()
		let translation = Translation(
			articleID: article.id,
			titleZh: titleZh,
			summaryZh: summaryZh,
			blocks: translatedBlocks,
			model: config.model,
			provider: "magpie",
			contentHash: Self.sha256Hex(of: source.hashSource),
			createdAt: now,
			updatedAt: now
		)
		try await store.saveTranslation(translation)
		return translation
	}

	// MARK: - Rewrite

	public func rewrite(_ article: AIArticle, kind: RewriteKind) async throws -> Rewrite {
		let source = article.contentText ?? article.contentHTML ?? ""
		guard !source.isEmpty else {
			throw AIEngineError.emptyContent
		}

		let system: String
		switch kind {
		case .article:
			system = AIPrompts.rewriteArticle
		case .paper:
			system = AIPrompts.rewritePaper
		case .productHunt:
			system = AIPrompts.rewriteProductHunt
		}

		let userContent = "标题：\(article.title)\n\n正文：\n\(source)"
		let output = try await client.complete(
			messages: [
				AIMessage(role: "system", content: system),
				AIMessage(role: "user", content: userContent)
			],
			temperature: nil,
			maxTokens: nil
		)
		let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !body.isEmpty else {
			throw AIEngineError.emptyContent
		}

		let now = Date()
		let rewrite = Rewrite(
			articleID: article.id,
			title: article.title,
			bodyMarkdown: body,
			bodyHTML: nil,
			model: config.model,
			contentHash: contentHash(for: article),
			createdAt: now,
			updatedAt: now
		)
		try await store.saveRewrite(rewrite)
		return rewrite
	}

	// MARK: - Chat

	public func chat(article: AIArticle, history: [ChatMessage], userMessage: String) async throws -> ChatMessage {
		var messages = [AIMessage(role: "system", content: AIPrompts.chatSystem + "\n\n当前文章上下文如下：\n" + articleContext(article))]
		messages.append(contentsOf: history.map { AIMessage(role: $0.role.rawValue, content: $0.content) })
		messages.append(AIMessage(role: "user", content: userMessage))

		let answer = try await client.complete(messages: messages, temperature: nil, maxTokens: nil)

		let userChatMessage = ChatMessage(
			id: UUID().uuidString,
			articleID: article.id,
			role: .user,
			content: userMessage,
			model: nil,
			createdAt: Date()
		)
		let assistantMessage = ChatMessage(
			id: UUID().uuidString,
			articleID: article.id,
			role: .assistant,
			content: answer,
			model: config.model,
			createdAt: Date()
		)
		try await store.appendChatMessage(userChatMessage)
		try await store.appendChatMessage(assistantMessage)
		return assistantMessage
	}
}

// MARK: - Source blocks

private extension AIEngine {

	struct SourceContent {
		let blocks: [SourceBlock]
		let hashSource: String
	}

	struct SourceBlock {
		let index: Int
		let text: String
		let html: String?
	}

	/// Estimate output tokens from the source size. Chinese output is roughly
	/// one token per two UTF-8 bytes of English source, so this errs on the
	/// side of splitting a little early.
	static func estimatedOutputTokens(for text: String) -> Int {
		max(1, text.utf8.count / 2)
	}

	static func textBlocks(from text: String, maxTokens: Int) -> [SourceBlock] {
		let byteBudget = max(1000, maxTokens * 2)
		var pieces: [String] = []
		for paragraph in text.components(separatedBy: "\n\n") {
			pieces.append(contentsOf: splitOversized(paragraph, byteBudget: byteBudget))
		}
		let nonEmpty = pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		let usable = nonEmpty.isEmpty ? [text] : nonEmpty
		return usable.enumerated().map { SourceBlock(index: $0.offset, text: $0.element, html: nil) }
	}

	static func splitOversized(_ text: String, byteBudget: Int) -> [String] {
		guard text.utf8.count > byteBudget else {
			return [text]
		}
		var pieces: [String] = []
		var current = ""
		for character in text {
			current.append(character)
			if current.utf8.count >= byteBudget {
				pieces.append(current)
				current = ""
			}
		}
		if !current.isEmpty {
			pieces.append(current)
		}
		return pieces
	}

	static func groupBlocks(_ blocks: [SourceBlock], maxTokens: Int) -> [[SourceBlock]] {
		let total = blocks.reduce(0) { $0 + estimatedOutputTokens(for: $1.text) }
		if total <= maxTokens {
			return [blocks]
		}

		var groups: [[SourceBlock]] = []
		var current: [SourceBlock] = []
		var currentTokens = 0
		for block in blocks {
			let tokens = estimatedOutputTokens(for: block.text)
			if !current.isEmpty && currentTokens + tokens > maxTokens {
				groups.append(current)
				current = [block]
				currentTokens = tokens
			} else {
				current.append(block)
				currentTokens += tokens
			}
		}
		if !current.isEmpty {
			groups.append(current)
		}
		return groups
	}
}

// MARK: - HTML splitting

private extension AIEngine {

	struct HTMLTag {
		let name: String
		let isClosing: Bool
		let isSelfClosing: Bool
		let endIndex: String.Index
	}

	static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]

	/// Splits HTML into top-level elements. Text between elements becomes its
	/// own block so that nothing is dropped.
	static func topLevelHTMLBlocks(_ html: String) -> [SourceBlock] {
		var blocks: [SourceBlock] = []
		var pendingText = ""
		var index = html.startIndex

		func flushPendingText() {
			let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				let blockIndex = blocks.count
				blocks.append(SourceBlock(index: blockIndex, text: decodeEntities(trimmed), html: trimmed))
			}
			pendingText = ""
		}

		while index < html.endIndex {
			let character = html[index]
			if character == "<", let end = elementEnd(html, from: index) {
				flushPendingText()
				let element = String(html[index..<end])
				let blockIndex = blocks.count
				blocks.append(SourceBlock(index: blockIndex, text: plainText(from: element), html: element))
				index = end
			} else {
				pendingText.append(character)
				index = html.index(after: index)
			}
		}
		flushPendingText()
		return blocks
	}

	static func elementEnd(_ html: String, from start: String.Index) -> String.Index? {
		if html[start...].hasPrefix("<!--") {
			guard let range = html.range(of: "-->", range: start..<html.endIndex) else {
				return html.endIndex
			}
			return range.upperBound
		}
		if html[start...].hasPrefix("<!") || html[start...].hasPrefix("<?") {
			guard let gt = html[start...].firstIndex(of: ">") else {
				return html.endIndex
			}
			return html.index(after: gt)
		}
		guard let first = scanTag(html, from: start) else {
			return nil
		}
		if first.isClosing || first.isSelfClosing || voidElements.contains(first.name) {
			return first.endIndex
		}

		var depth = 1
		var index = first.endIndex
		while index < html.endIndex {
			guard let lt = html[index...].firstIndex(of: "<") else {
				return html.endIndex
			}
			guard let tag = scanTag(html, from: lt) else {
				index = html.index(after: lt)
				continue
			}
			if tag.name == first.name {
				if tag.isClosing {
					depth -= 1
				} else if !tag.isSelfClosing && !voidElements.contains(tag.name) {
					depth += 1
				}
				if depth == 0 {
					return tag.endIndex
				}
			}
			index = tag.endIndex
		}
		return html.endIndex
	}

	static func scanTag(_ html: String, from start: String.Index) -> HTMLTag? {
		guard html[start] == "<" else {
			return nil
		}
		var index = html.index(after: start)
		guard index < html.endIndex else {
			return nil
		}

		var isClosing = false
		if html[index] == "/" {
			isClosing = true
			index = html.index(after: index)
		}
		guard index < html.endIndex, html[index].isLetter else {
			return nil
		}

		var name = ""
		while index < html.endIndex {
			let character = html[index]
			guard character.isLetter || character.isNumber || character == "-" || character == ":" else {
				break
			}
			name.append(character)
			index = html.index(after: index)
		}

		var quote: Character?
		var lastNonSpace: Character?
		while index < html.endIndex {
			let character = html[index]
			if let currentQuote = quote {
				if character == currentQuote {
					quote = nil
				}
			} else if character == "\"" || character == "'" {
				quote = character
			} else if character == ">" {
				let end = html.index(after: index)
				return HTMLTag(name: name.lowercased(), isClosing: isClosing, isSelfClosing: lastNonSpace == "/", endIndex: end)
			} else if !character.isWhitespace {
				lastNonSpace = character
			}
			index = html.index(after: index)
		}
		return nil
	}

	static func plainText(from html: String) -> String {
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
		return decodeEntities(result).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func decodeEntities(_ text: String) -> String {
		var result = text
		let replacements: [(String, String)] = [
			("&nbsp;", " "),
			("&lt;", "<"),
			("&gt;", ">"),
			("&quot;", "\""),
			("&#39;", "'"),
			("&apos;", "'"),
			("&amp;", "&")
		]
		for (entity, value) in replacements {
			result = result.replacingOccurrences(of: entity, with: value)
		}
		return result
	}
}

// MARK: - Helpers

private extension AIEngine {

	struct TitleItem: Encodable {
		let id: String
		let sourceId: String
		let title: String
		let context: String
	}

	struct TitleRequest: Encodable {
		let items: [TitleItem]
	}

	struct TitleResponse: Decodable {
		struct Entry: Decodable {
			let id: String
			let titleZh: String
		}
		let translations: [Entry]
	}

	struct TranslateBlock: Encodable {
		let i: Int
		let text: String
		let html: String?
	}

	struct TranslateRequest: Encodable {
		let title: String
		let summary: String
		let blocks: [TranslateBlock]
	}

	struct TranslateResponse: Decodable {
		struct Block: Decodable {
			let i: Int
			let target: String
			let targetHtml: String?
		}
		let titleZh: String?
		let summaryZh: String?
		let blocks: [Block]
	}

	func articleContext(_ article: AIArticle) -> String {
		var parts = ["标题：\(article.title)"]
		if let url = article.url {
			parts.append("链接：\(url)")
		}
		if let contentText = article.contentText {
			parts.append("正文：\n\(contentText)")
		} else if let contentHTML = article.contentHTML {
			parts.append("正文 HTML：\n\(contentHTML)")
		}
		return parts.joined(separator: "\n\n")
	}

	func contentHash(for article: AIArticle) -> String {
		let source = article.contentText ?? article.contentHTML ?? article.title
		return Self.sha256Hex(of: source)
	}

	static func sha256Hex(of text: String) -> String {
		let digest = SHA256.hash(data: Data(text.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}

	func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
		let json = extractJSONObject(from: raw)
		do {
			return try JSONDecoder().decode(type, from: Data(json.utf8))
		} catch {
			throw AIEngineError.invalidModelResponse(String(describing: error))
		}
	}

	func extractJSONObject(from raw: String) -> String {
		var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if text.hasPrefix("```") {
			if let firstNewline = text.firstIndex(of: "\n") {
				text = String(text[text.index(after: firstNewline)...])
			}
			if let fenceRange = text.range(of: "```", options: .backwards) {
				text = String(text[..<fenceRange.lowerBound])
			}
		}
		if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
			return String(text[start...end])
		}
		return text
	}
}

public enum AIEngineError: Error, Sendable {
	case emptyContent
	case invalidModelResponse(String)
	case incompleteTranslation(missing: [Int])
}
