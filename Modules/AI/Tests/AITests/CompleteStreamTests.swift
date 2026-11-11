//
//  CompleteStreamTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class SSEDecoderTests {

	@Test func decodesMultipleDeltasAndDone() {
		var decoder = SSEDecoder()
		#expect(decoder.event(forLine: #"data: {"choices":[{"delta":{"content":"你"}}]}"#) == .delta("你"))
		#expect(decoder.event(forLine: #"data: {"choices":[{"delta":{"content":"好"}}]}"#) == .delta("好"))
		#expect(decoder.event(forLine: "data: [DONE]") == .done)
	}

	@Test func ignoresBlankAndCommentLines() {
		var decoder = SSEDecoder()
		#expect(decoder.event(forLine: "") == .ignore)
		#expect(decoder.event(forLine: ": ping") == .ignore)
	}

	@Test func stripsTrailingCarriageReturn() {
		var decoder = SSEDecoder()
		#expect(decoder.event(forLine: "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\r") == .delta("x"))
	}

	@Test func ignoresNullDelta() {
		var decoder = SSEDecoder()
		#expect(decoder.event(forLine: #"data: {"choices":[{"delta":{"content":null}}]}"#) == .ignore)
		#expect(decoder.event(forLine: #"data: {"choices":[{"delta":null}]}"#) == .ignore)
		#expect(decoder.event(forLine: #"data: {"choices":[]}"#) == .ignore)
	}

	@Test func reportsTruncation() {
		var decoder = SSEDecoder()
		#expect(decoder.event(forLine: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#) == .truncated)
	}

	@Test func ignoresUndecodableDataLines() {
		var decoder = SSEDecoder()
		#expect(decoder.event(forLine: "data: not-json") == .ignore)
		#expect(decoder.event(forLine: "event: message") == .ignore)
	}

	@Test func eofWithContentFinishesCleanly() throws {
		var decoder = SSEDecoder()
		#expect(decoder.event(forLine: #"data: {"choices":[{"delta":{"content":"完整"}}]}"#) == .delta("完整"))
		try decoder.finish()
	}

	@Test func eofWithoutContentThrows() {
		let decoder = SSEDecoder()
		#expect(throws: AIClientError.self) {
			try decoder.finish()
		}
	}
}

@Suite(.serialized) final class OpenAIStreamClientTests {

	init() {
		StreamMockURLProtocol.reset()
	}

	@Test func nonEventStreamBodyYieldsOnce() async throws {
		StreamMockURLProtocol.handler = { _ in
			let json = #"{"choices":[{"message":{"content":"完整回复"}}]}"#
			return (200, ["Content-Type": "application/json"], Data(json.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model")
		let client = OpenAIChatClient(config: config, session: StreamMockURLProtocol.makeSession())

		var values: [String] = []
		for try await value in client.completeStream(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil, thinking: nil) {
			values.append(value)
		}
		#expect(values == ["完整回复"])
	}

	@Test func eventStreamYieldsDeltasInOrder() async throws {
		StreamMockURLProtocol.handler = { request in
			StreamMockURLProtocol.lastBody = StreamMockURLProtocol.bodyData(from: request)
			let body = """
			data: {"choices":[{"delta":{"content":"你"}}]}

			data: {"choices":[{"delta":{"content":"好"}}]}

			data: [DONE]

			"""
			return (200, ["Content-Type": "text/event-stream"], Data(body.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model")
		let client = OpenAIChatClient(config: config, session: StreamMockURLProtocol.makeSession())

		var values: [String] = []
		for try await value in client.completeStream(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil, thinking: nil) {
			values.append(value)
		}
		#expect(values == ["你", "好"])

		let body = try #require(StreamMockURLProtocol.lastBody)
		let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
		#expect(object["stream"] as? Bool == true)
	}
}

@Suite final class ChatStreamEngineTests {

	private let store: SQLiteAIStore
	private let databasePath: String

	init() {
		self.databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("ChatStreamEngineTests-\(UUID().uuidString).sqlite")
			.path
		self.store = SQLiteAIStore(databasePath: databasePath)
	}

	deinit {
		let fileManager = FileManager.default
		try? fileManager.removeItem(atPath: databasePath)
		try? fileManager.removeItem(atPath: databasePath + "-wal")
		try? fileManager.removeItem(atPath: databasePath + "-shm")
	}

	@Test func streamsDeltasAndPersistsFullText() async throws {
		let client = StreamingMockClient(deltas: ["你", "好", "，世界"])
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(id: "article-stream", title: "标题", contentText: "正文")

		var deltas: [String] = []
		var finishedMessage: ChatMessage?
		for try await event in engine.chatStream(article: article, history: [], userMessage: "问题") {
			switch event {
			case .delta(let text):
				deltas.append(text)
			case .finished(let message):
				finishedMessage = message
			}
		}

		#expect(deltas.joined() == "你好，世界")
		let message = try #require(finishedMessage)
		#expect(message.role == .assistant)
		#expect(message.content == "你好，世界")
		#expect(message.model == "test-model")

		let stored = try await store.chatMessages(for: "article-stream")
		#expect(stored.map(\.role) == [.user, .assistant])
		#expect(stored.map(\.content) == ["问题", "你好，世界"])
	}

	@Test func cancellationLeavesStoreEmpty() async throws {
		let client = StreamingMockClient(deltas: ["半截"], failure: CancellationError())
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(id: "article-cancel", title: "标题", contentText: "正文")

		var deltas: [String] = []
		do {
			for try await event in engine.chatStream(article: article, history: [], userMessage: "问题") {
				if case .delta(let text) = event {
					deltas.append(text)
				}
			}
			Issue.record("Expected cancellation")
		} catch is CancellationError {
			// Expected.
		} catch {
			Issue.record("Unexpected error: \(error)")
		}

		#expect(deltas == ["半截"])
		let stored = try await store.chatMessages(for: "article-cancel")
		#expect(stored.isEmpty)
	}

	@Test func errorLeavesStoreEmpty() async throws {
		let client = StreamingMockClient(deltas: ["半截"], failure: StreamTestError())
		let engine = AIEngine(store: store, client: client, config: AIConfig(model: "test-model"))
		let article = AIArticle(id: "article-error", title: "标题", contentText: "正文")

		do {
			for try await _ in engine.chatStream(article: article, history: [], userMessage: "问题") {
			}
			Issue.record("Expected an error")
		} catch is StreamTestError {
			// Expected.
		} catch {
			Issue.record("Unexpected error: \(error)")
		}

		let stored = try await store.chatMessages(for: "article-error")
		#expect(stored.isEmpty)
	}
}

private struct StreamTestError: Error, Sendable {}

private final class StreamingMockClient: AIClient, Sendable {

	private let deltas: [String]
	private let failure: (any Error & Sendable)?

	init(deltas: [String], failure: (any Error & Sendable)? = nil) {
		self.deltas = deltas
		self.failure = failure
	}

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		deltas.joined()
	}

	func completeStream(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) -> AsyncThrowingStream<String, Error> {
		let deltas = self.deltas
		let failure = self.failure
		return AsyncThrowingStream { continuation in
			for delta in deltas {
				continuation.yield(delta)
			}
			if let failure {
				continuation.finish(throwing: failure)
			} else {
				continuation.finish()
			}
		}
	}
}

private final class StreamMockURLProtocol: URLProtocol {

	nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
	nonisolated(unsafe) static var lastBody: Data?

	static func reset() {
		handler = nil
		lastBody = nil
	}

	static func bodyData(from request: URLRequest) -> Data? {
		if let body = request.httpBody {
			return body
		}
		guard let stream = request.httpBodyStream else {
			return nil
		}
		stream.open()
		defer {
			stream.close()
		}
		var data = Data()
		let bufferSize = 4096
		var buffer = [UInt8](repeating: 0, count: bufferSize)
		while stream.hasBytesAvailable {
			let read = stream.read(&buffer, maxLength: bufferSize)
			if read <= 0 {
				break
			}
			data.append(buffer, count: read)
		}
		return data
	}

	static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StreamMockURLProtocol.self]
		return URLSession(configuration: configuration)
	}

	override class func canInit(with request: URLRequest) -> Bool {
		true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		guard let handler = Self.handler else {
			client?.urlProtocol(self, didFailWithError: AIClientError.invalidResponse)
			return
		}
		do {
			let (status, headers, data) = try handler(request)
			let response = HTTPURLResponse(url: request.url ?? AIConfig.defaultBaseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
			if let response {
				client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			}
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override func stopLoading() {
	}
}
