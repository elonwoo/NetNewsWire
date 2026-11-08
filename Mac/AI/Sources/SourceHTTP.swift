//
//  SourceHTTP.swift
//  NetNewsWire
//

import Foundation
import RSWeb

/// A minimal request value for the source-fetching layer.
///
/// The source fetchers take an injectable loader so their parsing and fallback
/// behavior can be tested without touching the network.
struct SourceHTTPRequest: Sendable, Equatable {

	let url: URL
	let method: String
	let headers: [String: String]
	let body: Data?
	let timeout: TimeInterval

	init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 20) {
		self.url = url
		self.method = method
		self.headers = headers
		self.body = body
		self.timeout = timeout
	}
}

struct SourceHTTPResponse: Sendable, Equatable {

	let data: Data
	let statusCode: Int
	let mimeType: String?
	let finalURL: URL?
}

protocol SourceHTTPLoading: Sendable {

	func load(_ request: SourceHTTPRequest) async throws -> SourceHTTPResponse
}

enum SourceHTTPError: Error, Sendable, Equatable {

	case invalidResponse
	case httpStatus(Int)
	case emptyResponse
}

/// The production loader. Requests go through an ephemeral session so source
/// fetches never share cookies or the article cache with feed downloads.
struct URLSessionSourceLoader: SourceHTTPLoading {

	private let session: URLSession

	init(session: URLSession = URLSessionSourceLoader.makeSession()) {
		self.session = session
	}

	func load(_ request: SourceHTTPRequest) async throws -> SourceHTTPResponse {
		var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
		urlRequest.httpMethod = request.method
		urlRequest.httpBody = request.body
		for (field, value) in request.headers {
			urlRequest.setValue(value, forHTTPHeaderField: field)
		}

		let (data, response) = try await session.data(for: urlRequest)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw SourceHTTPError.invalidResponse
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw SourceHTTPError.httpStatus(httpResponse.statusCode)
		}
		guard !data.isEmpty else {
			throw SourceHTTPError.emptyResponse
		}
		return SourceHTTPResponse(data: data, statusCode: httpResponse.statusCode, mimeType: httpResponse.mimeType, finalURL: httpResponse.url)
	}

	private static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.httpShouldSetCookies = false
		configuration.httpCookieAcceptPolicy = .never
		configuration.timeoutIntervalForRequest = 20
		configuration.timeoutIntervalForResource = 40
		configuration.httpAdditionalHeaders = [HTTPRequestHeader.userAgent: SourceHTTPRequest.browserUserAgent]
		return URLSession(configuration: configuration)
	}
}

extension SourceHTTPRequest {

	/// Some hosts reject requests without a browser-like user agent.
	static var browserUserAgent: String {
		UserAgent.fromInfoPlist() ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) NetNewsWire"
	}

	static var browserHeaders: [String: String] {
		[
			HTTPRequestHeader.userAgent: browserUserAgent,
			"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.7",
			"Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8"
		]
	}
}
