//
//  RSSHubMultiInstanceClient.swift
//  NetNewsWire
//

import Foundation
import os
import RSCore

struct RSSHubInstance: Sendable, Equatable, Hashable, Codable {

	let baseURL: URL

	init?(_ string: String) {
		guard let url = URL(string: string),
			  let scheme = url.scheme?.lowercased(),
			  scheme == "https" || scheme == "http",
			  let host = url.host,
			  !host.isEmpty else {
			return nil
		}
		self.baseURL = url
	}

	/// Joins an RSSHub route onto the instance, keeping any path prefix the
	/// instance already has.
	func url(for path: String) -> URL? {
		var base = baseURL.absoluteString
		while base.hasSuffix("/") {
			base.removeLast()
		}
		var route = path
		while route.hasPrefix("/") {
			route.removeFirst()
		}
		guard !route.isEmpty else {
			return baseURL
		}
		return URL(string: base + "/" + route)
	}
}

enum RSSHubInstanceDefaults {

	/// Tried in order. The first instance is the one observed to be reachable
	/// most consistently; the rest are public fallbacks.
	static let all: [RSSHubInstance] = [
		"https://rsshub.bestblogs.dev",
		"https://rsshub.rssforever.com",
		"https://rsshub.ktachibana.party",
		"https://rsshub.app"
	].compactMap { RSSHubInstance($0) }
}

struct RSSHubFetchAttempt: Sendable, Equatable {

	let instance: RSSHubInstance
	let url: URL
	let errorDescription: String?
}

struct RSSHubFetchResult: Sendable, Equatable {

	let data: Data
	let instance: RSSHubInstance
	let url: URL
	/// Failures that happened before this instance succeeded.
	let attempts: [RSSHubFetchAttempt]
}

enum RSSHubFetchError: Error, Sendable, Equatable {

	case allInstancesFailed([RSSHubFetchAttempt])
}

/// Fetches one RSSHub route from a list of candidate instances.
///
/// Instances are tried in order. A network error, a non-2xx status or an empty
/// body counts as a failure for that instance; the next one is tried. The
/// fetch only fails when every candidate has failed.
struct RSSHubMultiInstanceClient: Sendable {

	private let loader: any SourceHTTPLoading
	private let instances: [RSSHubInstance]

	nonisolated private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "RSSHub")

	init(loader: any SourceHTTPLoading = URLSessionSourceLoader(), instances: [RSSHubInstance] = RSSHubInstanceDefaults.all) {
		self.loader = loader
		self.instances = instances
	}

	func fetch(path: String) async throws -> RSSHubFetchResult {
		try await fetch(path: path, instances: instances)
	}

	func fetch(path: String, instances: [RSSHubInstance]) async throws -> RSSHubFetchResult {
		var attempts: [RSSHubFetchAttempt] = []

		for instance in instances {
			guard let url = instance.url(for: path) else {
				attempts.append(RSSHubFetchAttempt(instance: instance, url: instance.baseURL, errorDescription: "Invalid route"))
				continue
			}

			do {
				let response = try await loader.load(SourceHTTPRequest(url: url, headers: SourceHTTPRequest.browserHeaders))
				guard !response.data.isEmpty else {
					throw SourceHTTPError.emptyResponse
				}
				return RSSHubFetchResult(data: response.data, instance: instance, url: url, attempts: attempts)
			} catch {
				Self.logger.debug("RSSHub instance failed: \(instance.baseURL.absoluteString, privacy: .public)")
				attempts.append(RSSHubFetchAttempt(instance: instance, url: url, errorDescription: String(describing: error)))
			}
		}

		throw RSSHubFetchError.allInstancesFailed(attempts)
	}
}
