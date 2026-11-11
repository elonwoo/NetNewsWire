//
//  Engine.swift
//  AI
//

import Foundation
import os

public enum RewriteKind: String, Sendable {
	case article
	case paper
	case productHunt
}

/// Orchestrates prompts, model calls and persistence.
///
/// The engine never truncates article bodies: rewrites and chat send the full
/// source. Translation is sent in groups sized by the prompt budget; every
/// block must come back before anything is saved.
public actor AIEngine {

	private let store: AIStore
	private let client: AIClient
	private let config: AIConfig

	private static let titleBatchSize = 20
	private static let logger = Logger(subsystem: "com.ranchero.NetNewsWire", category: "AIEngine")

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
				hashes[article.id] = ContentFingerprint.title(for: article)
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
		let prepared = try Self.prepareTranslation(article, maxTokens: config.maxTokens)
		var responses: [Int: TranslateResponse.Block] = [:]
		var titleZh: String?
		var summaryZh: String?

		let sendablePlans = prepared.plans.filter(\.isTranslatable)
		if !sendablePlans.isEmpty {
			let groups = Self.groupPlans(sendablePlans, maxTokens: config.maxTokens)
			for group in groups {
				let payloadBlocks = group.map { plan in
					TranslateBlock(i: plan.index, tag: plan.tag, text: HTMLSourceBlocks.escapeRequestText(plan.promptText))
				}
				let request = TranslateRequest(title: HTMLSourceBlocks.escapeRequestText(article.title), blocks: payloadBlocks)
				let payload = try JSONEncoder().encode(request)
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

				let expected = Set(group.map(\.index))
				let received = Set(response.blocks.map(\.i))
				let missing = expected.subtracting(received)
				guard missing.isEmpty else {
					throw AIEngineError.incompleteTranslation(missing: missing.sorted())
				}
				for block in response.blocks {
					guard !block.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
						throw AIEngineError.invalidModelResponse("empty translation target")
					}
					responses[block.i] = block
				}
				if titleZh == nil {
					titleZh = response.titleZh
				}
				if summaryZh == nil {
					summaryZh = response.summaryZh
				}
			}
		}

		var translatedBlocks: [TranslationBlock] = []
		for plan in prepared.plans {
			if plan.isTranslatable {
				guard let response = responses[plan.index] else {
					throw AIEngineError.incompleteTranslation(missing: [plan.index])
				}
				let block = try Self.fill(plan: plan, response: response, original: prepared.blocks[plan.index])
				translatedBlocks.append(block)
			} else {
				translatedBlocks.append(Self.autoFill(plan: plan, block: prepared.blocks[plan.index]))
			}
		}
		guard !translatedBlocks.isEmpty else {
			throw AIEngineError.emptyContent
		}

		let now = Date()
		let translation = Translation(
			articleID: article.id,
			titleZh: titleZh,
			summaryZh: summaryZh,
			blocks: translatedBlocks,
			model: config.model,
			provider: "magpie",
			contentHash: ContentFingerprint.body(for: article),
			createdAt: now,
			updatedAt: now
		)
		try await store.saveTranslation(translation)
		return translation
	}

	// MARK: - Rewrite

	public func rewrite(_ article: AIArticle, kind: RewriteKind, fingerprintArticle: AIArticle? = nil, fullText: Bool = false) async throws -> Rewrite {
		let fingerprint = fingerprintArticle ?? article
		let source = RewriteSourceBuilder.source(for: article)
		guard !source.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

		let userContent = Self.rewriteUserMessage(title: article.title, url: article.url, source: source)
		let output = try await client.complete(
			messages: [
				AIMessage(role: "system", content: system),
				AIMessage(role: "user", content: userContent)
			],
			temperature: nil,
			maxTokens: nil
		)
		let body = RewriteOutputNormalizer.normalize(output, images: source.images)
		guard !body.isEmpty else {
			throw AIEngineError.emptyContent
		}

		let now = Date()
		let baseHash = ContentFingerprint.rewrite(for: fingerprint, kind: kind)
		let rewrite = Rewrite(
			articleID: article.id,
			title: article.title,
			bodyMarkdown: body,
			bodyHTML: nil,
			model: config.model,
			contentHash: fullText ? "ft:" + baseHash : baseHash,
			createdAt: now,
			updatedAt: now
		)
		try await store.saveRewrite(rewrite)
		return rewrite
	}

	// MARK: - Chat

	public func chat(article: AIArticle, history: [ChatMessage], userMessage: String) async throws -> ChatMessage {
		let messages = chatMessages(article: article, history: history, userMessage: userMessage)

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

	/// Streams a chat answer. Deltas arrive as they are produced; the user and
	/// assistant messages are persisted only after the stream completes, so a
	/// cancelled or failed stream leaves the store untouched.
	public nonisolated func chatStream(article: AIArticle, history: [ChatMessage], userMessage: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let messages = await self.chatMessages(article: article, history: history, userMessage: userMessage)
					let client = self.client
					let config = self.config
					let store = self.store

					var answer = ""
					for try await delta in client.completeStream(messages: messages, temperature: nil, maxTokens: nil, thinking: nil) {
						try Task.checkCancellation()
						answer += delta
						continuation.yield(.delta(delta))
					}

					try Task.checkCancellation()
					guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
						throw AIEngineError.emptyContent
					}

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

					try Task.checkCancellation()
					try await store.appendChatMessage(userChatMessage)
					try Task.checkCancellation()
					try await store.appendChatMessage(assistantMessage)
					try Task.checkCancellation()

					continuation.yield(.finished(assistantMessage))
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	private func chatMessages(article: AIArticle, history: [ChatMessage], userMessage: String) -> [AIMessage] {
		var messages = [AIMessage(role: "system", content: AIPrompts.chatSystem + "\n\n当前文章上下文如下：\n" + articleContext(article))]
		messages.append(contentsOf: history.map { AIMessage(role: $0.role.rawValue, content: $0.content) })
		messages.append(AIMessage(role: "user", content: userMessage))
		return messages
	}
}

/// Events emitted by `AIEngine.chatStream`.
public enum AIChatStreamEvent: Sendable {
	case delta(String)
	case finished(ChatMessage)
}

// MARK: - Rewrite input

private extension AIEngine {

	static func rewriteUserMessage(title: String, url: String?, source: RewriteSource) -> String {
		var parts = ["标题：\(title)"]
		if let url, !url.isEmpty {
			parts.append("链接：\(url)")
		}
		if !source.images.isEmpty {
			var lines = ["图片锚点清单："]
			for (index, image) in source.images.enumerated() {
				lines.append("{{img:\(index)}} -> \(markdownImage(image))")
				if let caption = image.caption, !caption.isEmpty {
					lines.append("{{caption:\(index)}} -> \(caption)")
				}
			}
			parts.append(lines.joined(separator: "\n"))
		}
		parts.append("待处理材料：\n\(source.promptText)")
		return parts.joined(separator: "\n\n")
	}

	static func markdownImage(_ image: HTMLImageRef) -> String {
		let alt = image.alt.replacingOccurrences(of: "]", with: "")
		return "![\(alt)](\(image.url))"
	}
}

// MARK: - Translation preparation

private extension AIEngine {

	struct PreparedTranslation {
		let blocks: [HTMLSourceBlock]
		let plans: [TranslationBlockPlan]
	}

	static func prepareTranslation(_ article: AIArticle, maxTokens: Int) throws -> PreparedTranslation {
		if let html = article.contentHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let blocks = HTMLSourceBlocks.blocks(html, baseURL: article.url.flatMap { URL(string: $0) })
			guard !blocks.isEmpty else {
				throw AIEngineError.emptyContent
			}
			return PreparedTranslation(blocks: blocks, plans: TranslationBlockPlanner.plans(from: blocks))
		}
		let text = article.contentText ?? ""
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw AIEngineError.emptyContent
		}
		let (blocks, plans) = TranslationBlockPlanner.textPlans(from: text, maxTokens: maxTokens)
		return PreparedTranslation(blocks: blocks, plans: plans)
	}

	/// Estimate output tokens from the source size. Chinese output is roughly
	/// one token per two UTF-8 bytes of English source, so this errs on the side
	/// of splitting a little early.
	static func estimatedOutputTokens(for text: String) -> Int {
		max(1, text.utf8.count / 2)
	}

	static func groupPlans(_ plans: [TranslationBlockPlan], maxTokens: Int) -> [[TranslationBlockPlan]] {
		let total = plans.reduce(0) { $0 + estimatedOutputTokens(for: $1.promptText) }
		if total <= maxTokens {
			return [plans]
		}

		var groups: [[TranslationBlockPlan]] = []
		var current: [TranslationBlockPlan] = []
		var currentTokens = 0
		for plan in plans {
			let tokens = estimatedOutputTokens(for: plan.promptText)
			if !current.isEmpty, currentTokens + tokens > maxTokens {
				groups.append(current)
				current = [plan]
				currentTokens = tokens
			} else {
				current.append(plan)
				currentTokens += tokens
			}
		}
		if !current.isEmpty {
			groups.append(current)
		}
		return groups
	}

	static func autoFill(plan: TranslationBlockPlan, block: HTMLSourceBlock) -> TranslationBlock {
		switch plan.kind {
		case .code:
			return TranslationBlock(index: plan.index, source: block.text, target: block.text, targetHTML: block.html)
		case .media:
			return TranslationBlock(index: plan.index, source: block.images.first?.alt ?? "", target: "", targetHTML: block.html)
		case .table:
			return TranslationBlock(index: plan.index, source: block.text, target: "", targetHTML: block.html)
		case .text:
			return TranslationBlock(index: plan.index, source: block.images.first?.alt ?? "", target: "", targetHTML: block.html)
		}
	}

	static func fill(plan: TranslationBlockPlan, response: TranslateResponse.Block, original: HTMLSourceBlock) throws -> TranslationBlock {
		let raw = response.target.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !raw.isEmpty else {
			throw AIEngineError.invalidModelResponse("empty translation target")
		}
		let sourceText = plan.slotTexts.joined(separator: " ")
		if HTMLSourceBlocks.looksEnglish(sourceText), !HTMLSourceBlocks.containsHan(raw) {
			throw AIEngineError.invalidModelResponse("translation does not contain Chinese")
		}

		if plan.slotCount <= 1 {
			let htmlText = HTMLSourceBlocks.escapedHTMLText(raw)
			var targetHTML: String?
			if !plan.templateHTML.isEmpty {
				let marker = "\(plan.markerPrefix)0}}"
				if plan.templateHTML.contains(marker) {
					targetHTML = plan.templateHTML.replacingOccurrences(of: marker, with: htmlText)
				} else {
					targetHTML = wrap(plan.tag, htmlText)
				}
			}
			let target = stripMarkers(raw, prefix: plan.markerPrefix, count: max(plan.slotCount, 1))
			return TranslationBlock(index: plan.index, source: plan.displayText, target: target, targetHTML: targetHTML)
		}

		let markers = (0..<plan.slotCount).map { "\(plan.markerPrefix)\($0)}}" }
		var ranges: [Range<String.Index>] = []
		var searchStart = raw.startIndex
		for marker in markers {
			guard let range = raw.range(of: marker, range: searchStart..<raw.endIndex) else {
				return markerMismatch(plan: plan, raw: raw, original: original)
			}
			ranges.append(range)
			searchStart = range.upperBound
		}

		// Table prompts join cells with " | ", so a cell translation that precedes
		// another marker ends with that separator. Drop only the leading/trailing
		// pipes and whitespace; pipes inside a cell stay.
		let tableTrimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|"))
		var slotTranslations: [String] = []
		for (index, range) in ranges.enumerated() {
			let end = index + 1 < ranges.count ? ranges[index + 1].lowerBound : raw.endIndex
			let translation = String(raw[range.upperBound..<end])
			let trimSet = plan.kind == .table ? tableTrimSet : CharacterSet.whitespacesAndNewlines
			slotTranslations.append(translation.trimmingCharacters(in: trimSet))
		}

		var template = plan.templateHTML
		for (index, marker) in markers.enumerated() {
			guard template.contains(marker) else {
				return markerMismatch(plan: plan, raw: raw, original: original)
			}
			template = template.replacingOccurrences(of: marker, with: HTMLSourceBlocks.escapedHTMLText(slotTranslations[index]))
		}
		let target = stripMarkers(raw, prefix: plan.markerPrefix, count: plan.slotCount)
		return TranslationBlock(index: plan.index, source: plan.displayText, target: target, targetHTML: template)
	}

	static func markerMismatch(plan: TranslationBlockPlan, raw: String, original: HTMLSourceBlock) -> TranslationBlock {
		logger.error("AI translation markers out of order for block \(plan.index, privacy: .public)")
		if plan.kind == .table {
			return TranslationBlock(index: plan.index, source: plan.displayText, target: plan.displayText, targetHTML: original.html)
		}
		let stripped = stripMarkers(raw, prefix: plan.markerPrefix, count: max(plan.slotCount, 1))
		return TranslationBlock(index: plan.index, source: plan.displayText, target: stripped, targetHTML: wrap(plan.tag, HTMLSourceBlocks.escapedHTMLText(stripped)))
	}

	static func wrap(_ tag: String, _ html: String) -> String {
		guard !tag.isEmpty, tag != "#text" else {
			return html
		}
		return "<\(tag)>\(html)</\(tag)>"
	}

	static func stripMarkers(_ text: String, prefix: String, count: Int) -> String {
		var result = text
		for index in 0..<count {
			result = result.replacingOccurrences(of: "\(prefix)\(index)}}", with: " ")
		}
		result = result.replacingOccurrences(of: #"\{\{[A-Za-z_]*\d+\}\}"#, with: " ", options: .regularExpression)
		result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
		return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
		let tag: String
		let text: String
	}

	struct TranslateRequest: Encodable {
		let title: String
		let blocks: [TranslateBlock]
	}

	struct TranslateResponse: Decodable {
		struct Block: Decodable {
			let i: Int
			let target: String
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
