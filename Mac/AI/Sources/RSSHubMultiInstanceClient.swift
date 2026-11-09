//
//  RSSHubMultiInstanceClient.swift
//  NetNewsWire
//

import Foundation
import os
import RSCore
import RSWeb

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
