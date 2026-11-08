//
//  AIEnvironment.swift
//  NetNewsWire
//

import Foundation
import AI
import Secrets

/// App-side entry point for the AI stack.
///
/// Owns the database, model client, engine and job queue. Everything else in
/// the app goes through this object instead of building its own copies.
@MainActor
final class AIEnvironment {

	static let shared = AIEnvironment()

	private static let credentialServer = "magpie"
	private static let credentialUsername = "magpie"

	let store: SQLiteAIStore
	let queue: AIQueue
	private(set) var engine: AIEngine
	private(set) var config: AIConfig

	private init() {
		let apiKey = Self.loadAPIKey()
		let config = AIConfig(apiKey: apiKey)
		let store = SQLiteAIStore(databasePath: Self.databasePath)
		self.config = config
		self.store = store
		self.queue = AIQueue(store: store)
		self.engine = AIEngine(store: store, client: OpenAIChatClient(config: config), config: config)
	}

	var hasAPIKey: Bool {
		guard let apiKey = config.apiKey else {
			return false
		}
		return !apiKey.isEmpty
	}

	/// Stores a new gateway key and rebuilds the engine so subsequent requests
	/// use it. The database and queue are untouched.
	func updateAPIKey(_ apiKey: String) throws {
		try Self.saveAPIKey(apiKey)
		let config = AIConfig(apiKey: apiKey)
		self.config = config
		self.engine = AIEngine(store: store, client: OpenAIChatClient(config: config), config: config)
	}
}

private extension AIEnvironment {

	static var databasePath: String {
		let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		let folderURL = applicationSupportURL.appendingPathComponent("NetNewsWire", isDirectory: true)
		try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
		return folderURL.appendingPathComponent("AI.sqlite").path
	}

	static func loadAPIKey() -> String? {
		guard let credentials = try? CredentialsManager.retrieveCredentials(type: .aiAPIKey, server: credentialServer, username: credentialUsername) else {
			return nil
		}
		return credentials.secret
	}

	static func saveAPIKey(_ apiKey: String) throws {
		let credentials = Credentials(type: .aiAPIKey, username: credentialUsername, secret: apiKey)
		try CredentialsManager.storeCredentials(credentials, server: credentialServer)
	}
}
