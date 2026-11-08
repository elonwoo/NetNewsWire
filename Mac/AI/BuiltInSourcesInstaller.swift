//
//  BuiltInSourcesInstaller.swift
//  NetNewsWire
//

import Account
import Foundation
import os
import RSCore

/// Subscribes the built-in sources to the local account once.
///
/// The WeChat catalog is deliberately excluded: it holds hundreds of feeds and
/// is imported on demand from the File menu instead.
@MainActor
enum BuiltInSourcesInstaller {

	private static let didInstallKey = "AI.DidInstallBuiltInSources"
	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "BuiltInSources")

	static func installIfNeeded(account: Account) {
		guard !UserDefaults.standard.bool(forKey: didInstallKey) else {
			return
		}
		UserDefaults.standard.set(true, forKey: didInstallKey)

		let definitions = SourceCatalog.sources.filter { definition in
			if case .weChatCatalog = definition.endpoint {
				return false
			}
			return true
		}

		Task { @MainActor in
			for definition in definitions {
				await install(definition, in: account)
			}
		}
	}
}

private extension BuiltInSourcesInstaller {

	static func install(_ definition: SourceDefinition, in account: Account) async {
		let existingURLs = Set(account.flattenedFeeds().map(\.url))
		guard !definition.feedURLs.contains(where: { existingURLs.contains($0.absoluteString) }) else {
			return
		}

		for url in definition.feedURLs {
			if await subscribe(url: url, name: definition.displayName, account: account) {
				logger.info("Subscribed built-in source \(definition.id, privacy: .public)")
				return
			}
		}
		logger.error("Could not subscribe built-in source \(definition.id, privacy: .public)")
	}

	static func subscribe(url: URL, name: String, account: Account) async -> Bool {
		await withCheckedContinuation { continuation in
			account.createFeed(url: url.absoluteString, name: name, container: account, validateFeed: false) { result in
				switch result {
				case .success:
					continuation.resume(returning: true)
				case .failure(let error):
					if let accountError = error as? AccountError, case .createErrorAlreadySubscribed = accountError {
						continuation.resume(returning: true)
					} else {
						continuation.resume(returning: false)
					}
				}
			}
		}
	}
}
