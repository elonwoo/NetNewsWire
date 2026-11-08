//
//  OpenAIChatClientTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite(.serialized) final class OpenAIChatClientTests {

	init() {
		MockURLProtocol.reset()
	}

	@Test func sendsOpenAICompatibleRequestAndParsesContent() async throws {
		MockURLProtocol.handler = { request in
			MockURLProtocol.lastRequest = request
			MockURLProtocol.lastBody = MockURLProtocol.bodyData(from: request)
			let json = #"{"choices":[{"message":{"role":"assistant","content":"你好，世界"}}]}"#
			return (200, Data(json.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model", apiKey: "dummy-key-for-tests", temperature: 0.5, maxTokens: 123)
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		let result = try await client.complete(
			messages: [
				AIMessage(role: "system", content: "system"),
				AIMessage(role: "user", content: "hello")
			],
			temperature: nil,
			maxTokens: nil
		)
		#expect(result == "你好，世界")

		let request = try #require(MockURLProtocol.lastRequest)
		#expect(request.url?.absoluteString == "http://example.com/v1/chat/completions")
		#expect(request.httpMethod == "POST")
		#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-key-for-tests")

		let body = try #require(MockURLProtocol.lastBody)
		let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
		#expect(object["model"] as? String == "test-model")
		#expect(object["temperature"] as? Double == 0.5)
		#expect(object["max_tokens"] as? Int == 123)

		let messages = try #require(object["messages"] as? [[String: Any]])
		#expect(messages.count == 2)
		#expect(messages[0]["role"] as? String == "system")
		#expect(messages[0]["content"] as? String == "system")
		#expect(messages[1]["role"] as? String == "user")
		#expect(messages[1]["content"] as? String == "hello")
	}

	@Test func perCallOverridesTakePrecedence() async throws {
		MockURLProtocol.handler = { request in
			MockURLProtocol.lastBody = MockURLProtocol.bodyData(from: request)
			let json = #"{"choices":[{"message":{"content":"ok"}}]}"#
			return (200, Data(json.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model", temperature: 0.5, maxTokens: 123)
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		_ = try await client.complete(
			messages: [AIMessage(role: "user", content: "hi")],
			temperature: 0.9,
			maxTokens: 42
		)

		let body = try #require(MockURLProtocol.lastBody)
		let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
		#expect(object["temperature"] as? Double == 0.9)
		#expect(object["max_tokens"] as? Int == 42)
	}

	@Test func omitsAuthorizationHeaderWhenNoAPIKey() async throws {
		MockURLProtocol.handler = { request in
			MockURLProtocol.lastRequest = request
			let json = #"{"choices":[{"message":{"content":"ok"}}]}"#
			return (200, Data(json.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model", apiKey: nil)
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		_ = try await client.complete(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil)

		let request = try #require(MockURLProtocol.lastRequest)
		#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
	}

	@Test func throwsHTTPStatusErrorOnFailureResponse() async throws {
		MockURLProtocol.handler = { _ in
			(500, Data())
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model")
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		do {
			_ = try await client.complete(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil)
			Issue.record("Expected an error")
		} catch let error as AIClientError {
			switch error {
			case .httpStatus(let status):
				#expect(status == 500)
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}

	@Test func throwsMissingContentWhenChoicesAreEmpty() async throws {
		MockURLProtocol.handler = { _ in
			(200, Data(#"{"choices":[]}"#.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model")
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		do {
			_ = try await client.complete(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil)
			Issue.record("Expected an error")
		} catch let error as AIClientError {
			switch error {
			case .missingContent:
				break
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}

	@Test func throwsTruncatedWhenBudgetRunsOut() async throws {
		MockURLProtocol.handler = { _ in
			let json = #"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#
			return (200, Data(json.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model")
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		do {
			_ = try await client.complete(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil)
			Issue.record("Expected an error")
		} catch let error as AIClientError {
			switch error {
			case .truncated:
				break
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}

	@Test func throwsEmptyContentWhenAnswerIsBlank() async throws {
		MockURLProtocol.handler = { _ in
			let json = #"{"choices":[{"finish_reason":"stop","message":{"content":"   "}}]}"#
			return (200, Data(json.utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model")
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		do {
			_ = try await client.complete(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil)
			Issue.record("Expected an error")
		} catch let error as AIClientError {
			switch error {
			case .emptyContent:
				break
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}

	@Test func throwsInvalidResponseOnMalformedJSON() async throws {
		MockURLProtocol.handler = { _ in
			(200, Data("not json".utf8))
		}

		let baseURL = try #require(URL(string: "http://example.com/v1"))
		let config = AIConfig(baseURL: baseURL, model: "test-model")
		let client = OpenAIChatClient(config: config, session: MockURLProtocol.makeSession())

		do {
			_ = try await client.complete(messages: [AIMessage(role: "user", content: "hi")], temperature: nil, maxTokens: nil)
			Issue.record("Expected an error")
		} catch let error as AIClientError {
			switch error {
			case .invalidResponse:
				break
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}
}

private final class MockURLProtocol: URLProtocol {

	nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
	nonisolated(unsafe) static var lastRequest: URLRequest?
	nonisolated(unsafe) static var lastBody: Data?

	static func reset() {
		handler = nil
		lastRequest = nil
		lastBody = nil
	}

	static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [MockURLProtocol.self]
		return URLSession(configuration: configuration)
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
			let (status, data) = try handler(request)
			let response = HTTPURLResponse(url: request.url ?? AIConfig.defaultBaseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
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
