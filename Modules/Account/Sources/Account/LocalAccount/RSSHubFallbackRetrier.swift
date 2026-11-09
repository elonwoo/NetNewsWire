//
//  RSSHubFallbackRetrier.swift
//  Account
//

import Foundation
import RSWeb

struct RSSHubFallbackResponse: Sendable, Equatable {

	let data: Data
	let statusCode: Int
	let url: URL
}

protocol RSSHubFallbackLoading: Sendable {

	func load(_ url: URL) async throws -> RSSHubFallbackResponse
}

enum RSSHubFallbackError: Error, Sendable, Equatable {

	case noCandidates
	case httpStatus(Int)
	case emptyResponse
	case allCandidatesFailed([RSSHubFallbackAttempt])
}

struct RSSHubFallbackAttempt: Sendable, Equatable {

	let url: URL
	let errorDescription: String
}

struct RSSHubFallbackSuccess: Sendable, Equatable {

	let data: Data
	let url: URL
}

/// Fetches one RSSHub route from the configured instances, skipping the host
/// the feed is already subscribed to.
///
/// Candidates run serially. A network error, a non-2xx status or an empty body
/// fails that candidate; only a non-empty 2xx response succeeds. Different
/// feeds may run their chains concurrently.
struct RSSHubFallbackRetrier: Sendable {

	private let loader: any RSSHubFallbackLoading
	private let instances: [RSSHubInstance]

	init(loader: any RSSHubFallbackLoading = URLSessionRSSHubFallbackLoader(), instances: [RSSHubInstance] = RSSHubInstanceDefaults.all) {
		self.loader = loader
		self.instances = instances
	}

	/// Candidate URLs for a feed on a known RSSHub instance: the same path and
	/// query on every other configured instance, in failover order.
	func candidateURLs(for feedURL: URL) -> [URL] {
		guard let originalHost = feedURL.host()?.lowercased() else {
			return []
		}
		guard instances.contains(where: { $0.baseURL.host()?.lowercased() == originalHost }) else {
			return []
		}

		var seenHosts = Set([originalHost])
		var urls = [URL]()
		for instance in instances {
			guard let host = instance.baseURL.host()?.lowercased(), seenHosts.insert(host).inserted else {
				continue
			}
			if let url = Self.routeURL(for: instance, originalURL: feedURL) {
				urls.append(url)
			}
		}
		return urls
	}

	func fetch(feedURL: URL) async throws -> RSSHubFallbackSuccess {
		let candidates = candidateURLs(for: feedURL)
		guard !candidates.isEmpty else {
			throw RSSHubFallbackError.noCandidates
		}

		var attempts = [RSSHubFallbackAttempt]()
		for url in candidates {
			do {
				let response = try await loader.load(url)
				guard (200..<300).contains(response.statusCode) else {
					throw RSSHubFallbackError.httpStatus(response.statusCode)
				}
				guard !response.data.isEmpty else {
					throw RSSHubFallbackError.emptyResponse
				}
				return RSSHubFallbackSuccess(data: response.data, url: url)
			} catch {
				attempts.append(RSSHubFallbackAttempt(url: url, errorDescription: String(describing: error)))
			}
		}

		throw RSSHubFallbackError.allCandidatesFailed(attempts)
	}

	private static func routeURL(for instance: RSSHubInstance, originalURL: URL) -> URL? {
		guard var components = URLComponents(url: instance.baseURL, resolvingAgainstBaseURL: false),
			  let original = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
			return nil
		}

		var basePath = components.percentEncodedPath
		while basePath.hasSuffix("/") {
			basePath.removeLast()
		}
		var routePath = original.percentEncodedPath
		if !routePath.hasPrefix("/") {
			routePath = "/" + routePath
		}

		components.percentEncodedPath = basePath + routePath
		components.percentEncodedQuery = original.percentEncodedQuery
		components.fragment = nil
		return components.url
	}
}

/// The production loader. An ephemeral session keeps retries out of the feed
/// download session and the article cache.
struct URLSessionRSSHubFallbackLoader: RSSHubFallbackLoading {

	private let session: URLSession

	init(session: URLSession = URLSessionRSSHubFallbackLoader.makeSession()) {
		self.session = session
	}

	func load(_ url: URL) async throws -> RSSHubFallbackResponse {
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
		for (field, value) in Self.browserHeaders {
			request.setValue(value, forHTTPHeaderField: field)
		}

		let (data, response) = try await session.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw URLError(.badServerResponse)
		}
		return RSSHubFallbackResponse(data: data, statusCode: httpResponse.statusCode, url: httpResponse.url ?? url)
	}

	private static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.httpShouldSetCookies = false
		configuration.httpCookieAcceptPolicy = .never
		configuration.timeoutIntervalForRequest = 15
		configuration.timeoutIntervalForResource = 60
		configuration.httpAdditionalHeaders = browserHeaders
		return URLSession(configuration: configuration)
	}

	/// Matches the browser headers used by the source fetchers.
	private static var browserHeaders: [String: String] {
		let userAgent = UserAgent.fromInfoPlist() ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) NetNewsWire"
		return [
			HTTPRequestHeader.userAgent: userAgent,
			"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.7",
			"Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8"
		]
	}
}
