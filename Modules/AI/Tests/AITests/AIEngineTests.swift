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
		#expect(updated.contentHash != "old-hash")

		let inserted = try #require(try await store.translation(for: "article-2"))
		#expect(inserted.titleZh == "中文-New")
		#expect(inserted.blocks.isEmpty)
		#expect(inserted.provider == "magpie")
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

	// MARK: - HTML translation

	@Test func htmlTranslationSendsHTMLAndKeepsTargetHTML() async throws {
		let recorder = RequestRecorder()
		let client = MockAIClient { messages in
			recorder.record(messages)
			return try Self.translationResponse(for: messages)
		}
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let html = "<p>Hello <a href=\"https://example.com/article\">link</a></p>\n<p>Second paragraph</p>"
		let article = AIArticle(id: "article-html", title: "标题", contentHTML: html, contentText: "Hello link Second paragraph")

		let translation = try await engine.translateBody(article)

		#expect(translation.provider == "magpie")
		#expect(translation.blocks.count == 2)
		#expect(translation.blocks.allSatisfy { $0.targetHTML?.isEmpty == false })
		#expect(translation.blocks.contains { $0.targetHTML?.contains("https://example.com/article") == true })

		let request = try #require(recorder.requests.first)
		let userMessage = try #require(request.last)
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(userMessage.content.utf8)) as? [String: Any])
		let blocks = try #require(payload["blocks"] as? [[String: Any]])
		#expect(blocks.count == 2)
		#expect(blocks.allSatisfy { ($0["html"] as? String)?.isEmpty == false })

		let loaded = try #require(try await store.translation(for: "article-html"))
		#expect(loaded.articleID == translation.articleID)
		#expect(loaded.titleZh == translation.titleZh)
		#expect(loaded.blocks == translation.blocks)
		#expect(loaded.model == translation.model)
		#expect(loaded.provider == "magpie")
		#expect(loaded.contentHash == translation.contentHash)
	}

	@Test func textOnlyTranslationKeepsTextPath() async throws {
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

		let request = try #require(recorder.requests.first)
		let userMessage = try #require(request.last)
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(userMessage.content.utf8)) as? [String: Any])
		let blocks = try #require(payload["blocks"] as? [[String: Any]])
		#expect(blocks.allSatisfy { $0["html"] == nil })
	}
}

// MARK: - Mocks

private final class MockAIClient: AIClient, Sendable {

	private let handler: @Sendable ([AIMessage]) throws -> String

	init(handler: @escaping @Sendable ([AIMessage]) throws -> String) {
		self.handler = handler
	}

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?) async throws -> String {
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
			let html = block["html"] as? String
			var response: [String: Any] = ["i": index, "target": "中文"]
			if let html {
				response["targetHtml"] = html
			}
			return response
		}
		let response: [String: Any] = ["titleZh": "标题", "summaryZh": "", "blocks": responseBlocks]
		return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
	}
}
