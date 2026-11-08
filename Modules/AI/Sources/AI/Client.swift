//
//  Client.swift
//  AI
//

import Foundation

public struct AIMessage: Sendable, Equatable {
	public let role: String
	public let content: String

	public init(role: String, content: String) {
		self.role = role
		self.content = content
	}
}

public struct AIConfig: Sendable {
	public var baseURL: URL
	public var model: String
	public var apiKey: String?
	public var temperature: Double
	public var maxTokens: Int

	public static let defaultBaseURL: URL = {
		guard let url = URL(string: "http://127.0.0.1:3425/v1") else {
			fatalError("Invalid default AI base URL")
		}
		return url
	}()

	public static let defaultModel = "deepseek-v4.1-flash"

	public init(baseURL: URL = AIConfig.defaultBaseURL, model: String = AIConfig.defaultModel, apiKey: String? = nil, temperature: Double = 0.3, maxTokens: Int = 16384) {
		self.baseURL = baseURL
		self.model = model
		self.apiKey = apiKey
		self.temperature = temperature
		self.maxTokens = maxTokens
	}
}

public protocol AIClient: Sendable {
	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?) async throws -> String
}

/// Minimal OpenAI-compatible chat completions client.
///
/// Requests `POST {baseURL}/chat/completions` and reads
/// `choices[0].message.content` from the response.
public final class OpenAIChatClient: AIClient, Sendable {

	private let config: AIConfig
	private let session: URLSession

	public init(config: AIConfig, session: URLSession = .shared) {
		self.config = config
		self.session = session
	}

	public func complete(messages: [AIMessage], temperature: Double? = nil, maxTokens: Int? = nil) async throws -> String {
		let request = try makeRequest(messages: messages, temperature: temperature, maxTokens: maxTokens)
		let (data, response) = try await session.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw AIClientError.invalidResponse
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw AIClientError.httpStatus(httpResponse.statusCode)
		}
		let decoded: ChatCompletionResponse
		do {
			decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
		} catch {
			throw AIClientError.invalidResponse
		}
		guard let content = decoded.choices.first?.message.content else {
			throw AIClientError.missingContent
		}
		// Reasoning models spend part of the budget on reasoning tokens, so a
		// short budget can come back with an empty answer and finish_reason
		// "length". Treat that as a failure instead of persisting nothing.
		if decoded.choices.first?.finishReason == "length" {
			throw AIClientError.truncated
		}
		guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw AIClientError.emptyContent
		}
		return content
	}

	private func makeRequest(messages: [AIMessage], temperature: Double?, maxTokens: Int?) throws -> URLRequest {
		let url = config.baseURL.appendingPathComponent("chat/completions")
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		if let apiKey = config.apiKey, !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		}

		let body = ChatCompletionRequest(
			model: config.model,
			messages: messages.map { ChatCompletionRequest.Message(role: $0.role, content: $0.content) },
			temperature: temperature ?? config.temperature,
			maxTokens: maxTokens ?? config.maxTokens
		)
		request.httpBody = try JSONEncoder().encode(body)
		return request
	}
}

public enum AIClientError: Error, Sendable {
	case invalidResponse
	case httpStatus(Int)
	case missingContent
	case emptyContent
	case truncated
}

private struct ChatCompletionRequest: Encodable {

	struct Message: Encodable {
		let role: String
		let content: String
	}

	let model: String
	let messages: [Message]
	let temperature: Double
	let maxTokens: Int

	enum CodingKeys: String, CodingKey {
		case model
		case messages
		case temperature
		case maxTokens = "max_tokens"
	}
}

private struct ChatCompletionResponse: Decodable {

	struct Choice: Decodable {
		let message: Message
		let finishReason: String?

		enum CodingKeys: String, CodingKey {
			case message
			case finishReason = "finish_reason"
		}
	}

	struct Message: Decodable {
		let role: String?
		let content: String?
	}

	let choices: [Choice]
}
