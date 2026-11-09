//
//  RSSHubInstance.swift
//  RSWeb
//

import Foundation

public struct RSSHubInstance: Sendable, Equatable, Hashable, Codable {

	public let baseURL: URL

	public init?(_ string: String) {
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
	public func url(for path: String) -> URL? {
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

public enum RSSHubInstanceDefaults {

	/// Tried in order. The first instance is the one observed to be reachable
	/// most consistently; the rest are public fallbacks.
	public static let all: [RSSHubInstance] = [
		"https://rsshub.bestblogs.dev",
		"https://rsshub.rssforever.com",
		"https://rsshub.ktachibana.party",
		"https://rsshub.app"
	].compactMap { RSSHubInstance($0) }
}
