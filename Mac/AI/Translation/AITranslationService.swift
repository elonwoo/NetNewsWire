//
//  AITranslationService.swift
//  NetNewsWire
//

import AI
import Foundation

/// Title and body translation on top of the engine.
///
/// The engine already batches title requests and splits oversized bodies, so
/// this layer only handles caching, resume and job-level bookkeeping.
@MainActor
final class AITranslationService {

	private let store: AIStore
	private let engine: AIEngine
	private let bodyRunner: AIBodyTranslationRunner

	init(store: AIStore, engine: AIEngine, config: AIConfig) {
		self.store = store
		self.engine = engine
		self.bodyRunner = AIBodyTranslationRunner(store: store, engine: engine, config: config)
	}

	/// Translates the titles of the articles that do not have a current
	/// translation yet. Returns the IDs that were actually generated.
	@discardableResult
	func translateTitles(_ articles: [AIArticle]) async throws -> Set<String> {
		var pending: [AIArticle] = []
		for article in articles {
			guard !article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				continue
			}
			if let cached = try? await store.translation(for: article.id),
			   let titleZh = cached.titleZh,
			   !titleZh.isEmpty,
			   AIContentHash.matchesTitleHash(cached.contentHash, article: article) {
				continue
			}
			pending.append(article)
		}

		guard !pending.isEmpty else {
			return []
		}
		let translations = try await engine.translateTitles(pending)
		return Set(translations.keys)
	}

	@discardableResult
	func translateTitle(_ article: AIArticle) async throws -> Bool {
		let generated = try await translateTitles([article])
		return !generated.isEmpty
	}

	func translateBody(_ article: AIArticle) async throws -> AI.Translation {
		try await bodyRunner.translate(article)
	}
}
