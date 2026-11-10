//
//  AIEngineTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class AIEngineTests {

	private let store: SQLiteAIStore
	private let databasePath: String

	init() {
		self.databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIEngineTests-\(UUID().uuidString).sqlite")
			.path
		self.store = SQLiteAIStore(databasePath: databasePath)
	}

	deinit {
		let fileManager = FileManager.default
		try? fileManager.removeItem(atPath: databasePath)
		try? fileManager.removeItem(atPath: databasePath + "-wal")
		try? fileManager.removeItem(atPath: databasePath + "-shm")
	}

	// MARK: - Titles

	@Test func titleTranslationsArePersistedWithoutOverwritingBlocks() async throws {
		let existingDate = Date(timeIntervalSince1970: 1_700_000_000)
		let existingBlock = TranslationBlock(index: 0, source: "Hello", target: "你好", targetHTML: "<p>你好</p>")
		let existing = Translation(
			articleID: "article-1",
			titleZh: "旧标题",
			summaryZh: "摘要",
			blocks: [existingBlock],
			model: "old-model",
			provider: "magpie",
			contentHash: "old-hash",
			createdAt: existingDate,
			updatedAt: existingDate
		)
		try await store.saveTranslation(existing)

		let client = MockAIClient { messages in
			try Self.titleResponse(for: messages, prefix: "中文-")
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let articles = [
			AIArticle(id: "article-1", title: "Existing", contentText: "body one"),
			AIArticle(id: "article-2", title: "New", contentText: "body two")
		]

		let result = try await engine.translateTitles(articles)
		#expect(result["article-1"] == "中文-Existing")
		#expect(result["article-2"] == "中文-New")

		let updated = try #require(try await store.translation(for: "article-1"))
		#expect(updated.titleZh == "中文-Existing")
		#expect(updated.blocks == [existingBlock])
		#expect(updated.summaryZh == "摘要")
		#expect(updated.createdAt == existingDate)
		#expect(updated.model == "test-model")
		#expect(updated.provider == "magpie")
		#expect(updated.contentHash == ContentFingerprint.title(for: articles[0]))
		#expect(!updated.contentHash.hasPrefix("r2:"))
		#expect(!updated.contentHash.hasPrefix("b2:"))

		let inserted = try #require(try await store.translation(for: "article-2"))
		#expect(inserted.titleZh == "中文-New")
		#expect(inserted.blocks.isEmpty)
		#expect(inserted.provider == "magpie")
		#expect(inserted.contentHash == ContentFingerprint.title(for: articles[1]))
	}

	// MARK: - Chat

	@Test func chatPersistsUserAndAssistantMessages() async throws {
		let client = MockAIClient { _ in "这是回答" }
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(id: "article-chat", title: "标题", contentText: "正文")

		let reply = try await engine.chat(article: article, history: [], userMessage: "这是问题")

		#expect(reply.role == .assistant)
		#expect(reply.content == "这是回答")
		#expect(reply.model == "test-model")

		let messages = try await store.chatMessages(for: "article-chat")
		#expect(messages.count == 2)
		#expect(messages.map(\.role) == [.user, .assistant])
		#expect(messages.map(\.content) == ["这是问题", "这是回答"])
		#expect(messages.last?.id == reply.id)
		#expect(messages.last?.role == .assistant)
		#expect(messages.last?.model == "test-model")
	}

	// MARK: - Rewrite

	@Test func htmlRewriteRequestContainsNoRawHTML() async throws {
		let recorder = RequestRecorder()
		let client = MockAIClient { messages in
			recorder.record(messages)
			return "中文正文"
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-rewrite",
			title: "Title",
			contentHTML: #"<p>Hello <a href="https://example.com/x">link</a></p>"#
		)

		let rewrite = try await engine.rewrite(article, kind: .article)

		let request = try #require(recorder.requests.first)
		let userMessage = try #require(request.last)
		#expect(!userMessage.content.contains("<p"))
		#expect(!userMessage.content.contains("<a "))
		#expect(userMessage.content.contains("Hello"))
		#expect(userMessage.content.contains("[link](https://example.com/x)"))
		#expect(rewrite.contentHash.hasPrefix("r2:"))
	}

	@Test func rewriteOutputIsNormalized() async throws {
		let client = MockAIClient { _ in "# 标题\n\n正文 <img src=\"x\" <p>残留" }
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(id: "article-leak", title: "Title", contentHTML: "<p>Body</p>")

		let rewrite = try await engine.rewrite(article, kind: .article)

		#expect(!rewrite.bodyMarkdown.contains("<img"))
		#expect(!rewrite.bodyMarkdown.contains("<p"))
		#expect(!rewrite.bodyMarkdown.hasPrefix("# 标题"))
		#expect(rewrite.bodyMarkdown.contains("正文"))
	}

	// MARK: - HTML translation

	@Test func translationRequestContainsNoTags() async throws {
		let recorder = RequestRecorder()
		let client = MockAIClient { messages in
			recorder.record(messages)
			return try Self.translationResponse(for: messages)
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-html",
			title: "标题",
			contentHTML: #"<p>Hello <strong>world</strong> <a href="https://example.com/x">link</a></p>"#
		)

		let translation = try await engine.translateBody(article)

		let request = try #require(recorder.requests.first)
		let userMessage = try #require(request.last)
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(userMessage.content.utf8)) as? [String: Any])
		for value in Self.allStrings(in: payload) {
			#expect(value.range(of: #"<[A-Za-z/]"#, options: .regularExpression) == nil)
		}

		#expect(translation.contentHash.hasPrefix("b2:"))
		#expect(translation.blocks.count == 1)
		#expect(translation.blocks[0].targetHTML?.contains("<strong>") == true)
		#expect(translation.blocks[0].targetHTML?.contains("https://example.com/x") == true)
	}

	@Test func mediaAndCodeAreAutoFilledWithoutBeingSent() async throws {
		let recorder = RequestRecorder()
		let client = MockAIClient { messages in
			recorder.record(messages)
			return try Self.translationResponse(for: messages)
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-mixed",
			title: "标题",
			contentHTML: #"<p>Hello world</p><pre><code class="language-swift">let x = 1</code></pre><figure><img src="https://example.com/a.png" alt="A"></figure>"#
		)

		let translation = try await engine.translateBody(article)

		let request = try #require(recorder.requests.first)
		let userMessage = try #require(request.last)
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(userMessage.content.utf8)) as? [String: Any])
		let blocks = try #require(payload["blocks"] as? [[String: Any]])
		#expect(blocks.count == 1)
		#expect(recorder.requests.count == 1)

		#expect(translation.blocks.count == 3)
		#expect(translation.blocks[1].source == "let x = 1")
		#expect(translation.blocks[1].target == "let x = 1")
		#expect(translation.blocks[1].targetHTML?.contains("<pre") == true)
		#expect(translation.blocks[2].source == "A")
		#expect(translation.blocks[2].target.isEmpty)
		#expect(translation.blocks[2].targetHTML?.contains("<img") == true)
	}

	@Test func onlyMediaAndCodeDoesNotCallModel() async throws {
		let recorder = RequestRecorder()
		let client = MockAIClient { messages in
			recorder.record(messages)
			return try Self.translationResponse(for: messages)
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-media",
			title: "标题",
			contentHTML: #"<pre><code>let x = 1</code></pre><figure><img src="https://example.com/a.png" alt="A"></figure>"#
		)

		let translation = try await engine.translateBody(article)

		#expect(recorder.requests.isEmpty)
		#expect(!translation.blocks.isEmpty)
		#expect(translation.blocks.count == 2)
		#expect(translation.titleZh == nil)
		#expect(translation.summaryZh == nil)
		#expect(translation.contentHash.hasPrefix("b2:"))
	}

	@Test func tableMarkerMismatchKeepsSourceStructure() async throws {
		let client = MockAIClient { _ in
			try Self.translationJSON(blocks: [["i": 0, "target": "{{t1}}错{{t0}}位"]])
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-table",
			title: "标题",
			contentHTML: "<table><tr><td>One</td><td>Two</td></tr></table>"
		)

		let translation = try await engine.translateBody(article)
		let block = try #require(translation.blocks.first)

		#expect(block.target == "One | Two")
		#expect(block.targetHTML?.contains("<table") == true)
		#expect(block.targetHTML?.contains("One") == true)
		#expect(block.targetHTML?.contains("Two") == true)
	}

	@Test func tableFillDropsCellSeparatorsFromTranslations() async throws {
		let client = MockAIClient { _ in
			try Self.translationJSON(blocks: [["i": 0, "target": "{{t0}}名称 | {{t1}}值\n{{t2}}阿尔法 | {{t3}}1"]])
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-table-fill",
			title: "标题",
			contentHTML: "<table><tr><th>Name</th><th>Value</th></tr><tr><td>Alpha</td><td>1</td></tr></table>"
		)

		let translation = try await engine.translateBody(article)
		let block = try #require(translation.blocks.first)

		#expect(block.targetHTML?.contains("<th>名称</th>") == true)
		#expect(block.targetHTML?.contains("<th>值</th>") == true)
		#expect(block.targetHTML?.contains("<td>阿尔法</td>") == true)
		#expect(block.targetHTML?.contains("|") == false)
	}

	@Test func normalBlockMarkerMismatchWrapsOuterTag() async throws {
		let client = MockAIClient { _ in
			try Self.translationJSON(blocks: [["i": 0, "target": "{{t2}}中{{t0}}文{{t1}}字"]])
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-paragraph",
			title: "标题",
			contentHTML: "<p>First <em>second</em> third</p>"
		)

		let translation = try await engine.translateBody(article)
		let block = try #require(translation.blocks.first)

		#expect(block.targetHTML?.hasPrefix("<p>") == true)
		#expect(block.targetHTML?.contains("中") == true)
	}

	@Test func missingTranslatableBlockThrowsIncompleteTranslation() async throws {
		let client = MockAIClient { messages in
			let content = messages.last?.content ?? ""
			let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
			let blocks = object?["blocks"] as? [[String: Any]] ?? []
			let firstIndex = blocks.first?["i"] as? Int ?? 0
			return try Self.translationJSON(blocks: [["i": firstIndex, "target": "中文译文"]])
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(
			id: "article-two",
			title: "标题",
			contentHTML: "<p>First paragraph</p><p>Second paragraph</p>"
		)

		do {
			_ = try await engine.translateBody(article)
			Issue.record("Expected incompleteTranslation")
		} catch let error as AIEngineError {
			guard case .incompleteTranslation = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		} catch {
			Issue.record("Unexpected error: \(error)")
		}
	}

	@Test func textOnlyPathKeepsTextPath() async throws {
		let recorder = RequestRecorder()
		let client = MockAIClient { messages in
			recorder.record(messages)
			return try Self.translationResponse(for: messages)
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(id: "article-text", title: "标题", contentText: "First paragraph.\n\nSecond paragraph.")

		let translation = try await engine.translateBody(article)

		#expect(translation.blocks.count == 2)
		#expect(translation.blocks.allSatisfy { $0.targetHTML == nil })
		#expect(translation.contentHash.hasPrefix("b2:"))

		let request = try #require(recorder.requests.first)
		let userMessage = try #require(request.last)
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(userMessage.content.utf8)) as? [String: Any])
		let blocks = try #require(payload["blocks"] as? [[String: Any]])
		#expect(blocks.count == 2)
		#expect(blocks.allSatisfy { $0["tag"] as? String == "#text" })
		#expect(blocks.allSatisfy { $0["html"] == nil })
	}
}

// MARK: - Mocks

private final class MockAIClient: AIClient, Sendable {

	private let handler: @Sendable ([AIMessage]) throws -> String

	init(handler: @escaping @Sendable ([AIMessage]) throws -> String) {
		self.handler = handler
	}

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		try handler(messages)
	}
}

private final class RequestRecorder: @unchecked Sendable {

	private let lock = NSLock()
	private var storage: [[AIMessage]] = []

	func record(_ messages: [AIMessage]) {
		lock.lock()
		storage.append(messages)
		lock.unlock()
	}

	var requests: [[AIMessage]] {
		lock.lock()
		defer {
			lock.unlock()
		}
		return storage
	}
}

// MARK: - Response builders

private extension AIEngineTests {

	static func titleResponse(for messages: [AIMessage], prefix: String) throws -> String {
		let content = messages.last?.content ?? ""
		let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
		let items = object?["items"] as? [[String: Any]] ?? []
		let translations = items.compactMap { item -> [String: Any]? in
			guard let id = item["id"] as? String, let title = item["title"] as? String else {
				return nil
			}
			return ["id": id, "titleZh": prefix + title]
		}
		return String(decoding: try JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)
	}

	static func translationResponse(for messages: [AIMessage]) throws -> String {
		let content = messages.last?.content ?? ""
		let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
		let requestBlocks = object?["blocks"] as? [[String: Any]] ?? []
		let responseBlocks = requestBlocks.map { block -> [String: Any] in
			let index = block["i"] as? Int ?? 0
			let text = block["text"] as? String ?? ""
			let markers = markerList(in: text)
			let target: String
			if markers.isEmpty {
				target = "中文译文"
			} else {
				target = markers.map { $0 + "中文译文" }.joined()
			}
			return ["i": index, "target": target]
		}
		return try translationJSON(blocks: responseBlocks)
	}

	static func translationJSON(blocks: [[String: Any]]) throws -> String {
		let response: [String: Any] = ["titleZh": "标题", "summaryZh": "", "blocks": blocks]
		return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
	}

	static func markerList(in text: String) -> [String] {
		guard let regex = try? NSRegularExpression(pattern: #"\{\{[A-Za-z_]*\d+\}\}"#) else {
			return []
		}
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		return regex.matches(in: text, range: range).compactMap { match in
			Range(match.range, in: text).map { String(text[$0]) }
		}
	}

	static func allStrings(in value: Any) -> [String] {
		if let string = value as? String {
			return [string]
		}
		if let array = value as? [Any] {
			return array.flatMap { allStrings(in: $0) }
		}
		if let dictionary = value as? [String: Any] {
			return dictionary.values.flatMap { allStrings(in: $0) }
		}
		return []
	}
}
