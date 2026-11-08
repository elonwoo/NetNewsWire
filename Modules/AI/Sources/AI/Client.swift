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

/// Whether a reasoning model may spend tokens on its reasoning step.
///
/// Only translation turns thinking off; rewrites and chat keep the model default.
public enum AIThinkingMode: String, Sendable {
	case enabled
	case disabled
}

public protocol AIClient: Sendable {
	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String
}

public extension AIClient {
	func complete(messages: [AIMessage], temperature: Double? = nil, maxTokens: Int? = nil) async throws -> String {
		try await complete(messages: messages, temperature: temperature, maxTokens: maxTokens, thinking: nil)
	}
}

/// Minimal OpenAI-compatible chat completions client.
///
/// Requests `POST {baseURL}/chat/completions` and reads
/// `choices[0].message.content` from the response.
public final class OpenAIChatClient: AIClient, Sendable {

	private let config: AIConfig
	private let session: URLSession

	/// Long articles can take minutes to rewrite, so the default session allows
	/// far more time than `URLSession.shared` does.
	private static let defaultSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 240
		configuration.timeoutIntervalForResource = 480
		return URLSession(configuration: configuration)
	}()

	public init(config: AIConfig, session: URLSession? = nil) {
		self.config = config
		self.session = session ?? Self.defaultSession
	}

	public func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		let request = try makeRequest(messages: messages, temperature: temperature, maxTokens: maxTokens, thinking: thinking)
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

	/// Fetches the model IDs the gateway exposes at `GET {baseURL}/models`.
	public func availableModels() async throws -> [String] {
		var request = URLRequest(url: config.baseURL.appendingPathComponent("models"))
		request.httpMethod = "GET"
		if let apiKey = config.apiKey, !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		}

		let (data, response) = try await session.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw AIClientError.invalidResponse
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw AIClientError.httpStatus(httpResponse.statusCode)
		}
		guard let decoded = try? JSONDecoder().decode(ModelListResponse.self, from: data) else {
			throw AIClientError.invalidResponse
		}
		return decoded.data.map(\.id).filter { !$0.isEmpty }
	}

	private func makeRequest(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) throws -> URLRequest {
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
			maxTokens: maxTokens ?? config.maxTokens,
			thinking: thinking.map { ChatCompletionRequest.AIThinkingRequest(type: $0.rawValue) }
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

	struct AIThinkingRequest: Encodable {
		let type: String
	}

	let model: String
	let messages: [Message]
	let temperature: Double
	let maxTokens: Int
	let thinking: AIThinkingRequest?

	enum CodingKeys: String, CodingKey {
		case model
		case messages
		case temperature
		case maxTokens = "max_tokens"
		case thinking
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(model, forKey: .model)
		try container.encode(messages, forKey: .messages)
		try container.encode(temperature, forKey: .temperature)
		try container.encode(maxTokens, forKey: .maxTokens)
		try container.encodeIfPresent(thinking, forKey: .thinking)
	}
}

private struct ModelListResponse: Decodable {

	struct Model: Decodable {
		let id: String
	}

	let data: [Model]
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
