//
//  WeChatCatalogImporter.swift
//  NetNewsWire
//

import Account
import AppKit
import Foundation
import os
import RSCore

/// Imports the WeChat feeds from the built-in catalog into the local account.
///
/// The catalog is fetched on demand and written to a temporary OPML file whose
/// feeds live in a single “微信公众号” folder. Feeds that are already
/// subscribed are left out before the import.
@MainActor
final class WeChatCatalogImporter {

	static let shared = WeChatCatalogImporter()

	private static let folderName = "微信公众号"
	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "WeChatCatalog")

	private(set) var isImporting = false

	private init() {
	}

	func startImport() {
		guard !isImporting else {
			return
		}
		isImporting = true

		Task { @MainActor in
			defer {
				isImporting = false
			}
			do {
				try await performImport()
			} catch {
				NSApplication.shared.presentError(error)
			}
		}
	}
}

private extension WeChatCatalogImporter {

	func performImport() async throws {
		let catalog = try await WeChatCatalogLoader().load()
		let account = AccountManager.shared.defaultAccount
		let existingURLs = Set(account.flattenedFeeds().map(\.url))
		let feeds = catalog.weChatFeeds.filter { !existingURLs.contains($0.feedURL.absoluteString) }

		guard !feeds.isEmpty else {
			Self.logger.info("WeChat catalog has no new feeds to import")
			return
		}

		let opmlFile = try writeOPML(feeds: feeds)
		defer {
			try? FileManager.default.removeItem(at: opmlFile)
		}

		await importOPML(opmlFile, into: account)
		Self.logger.info("Imported \(feeds.count) WeChat feeds")
	}

	func importOPML(_ opmlFile: URL, into account: Account) async {
		await withCheckedContinuation { continuation in
			account.importOPML(opmlFile) { result in
				if case .failure(let error) = result {
					NSApplication.shared.presentError(error)
				}
				continuation.resume()
			}
		}
	}

	func writeOPML(feeds: [WeChatCatalogFeed]) throws -> URL {
		var lines = [
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
			"<opml version=\"2.0\">",
			"<head>",
			"<title>\(Self.escape(Self.folderName))</title>",
			"</head>",
			"<body>",
			"<outline text=\"\(Self.escape(Self.folderName))\" title=\"\(Self.escape(Self.folderName))\">"
		]

		for feed in feeds {
			let title = Self.escape(feed.title)
			let feedURL = Self.escape(feed.feedURL.absoluteString)
			var attributes = "<outline text=\"\(title)\" title=\"\(title)\" type=\"rss\""
			if let siteURL = feed.siteURL {
				attributes += " htmlUrl=\"\(Self.escape(siteURL.absoluteString))\""
			}
			attributes += " xmlUrl=\"\(feedURL)\"/>"
			lines.append(attributes)
		}

		lines.append("</outline>")
		lines.append("</body>")
		lines.append("</opml>")

		let fileURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("WeChatCatalog-\(UUID().uuidString).opml")
		try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
		return fileURL
	}

	static func escape(_ string: String) -> String {
		string
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}
}
