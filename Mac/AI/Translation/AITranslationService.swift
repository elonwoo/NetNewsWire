//
//  AITranslationService.swift
//  NetNewsWire
//

import AI
import Foundation

struct TitleTranslationResult: Sendable, Equatable {
	let translated: Set<String>
	let cached: Set<String>
	let failed: Set<String>

	init(translated: Set<String> = [], cached: Set<String> = [], failed: Set<String> = []) {
		self.translated = translated
		self.cached = cached
		self.failed = failed
	}
}

struct BodyTranslationResult: Sendable {
	let translation: AI.Translation
	let wasCached: Bool
}

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
	/// translation yet. Every input article lands in exactly one bucket.
	@discardableResult
	func translateTitles(_ articles: [AIArticle]) async throws -> TitleTranslationResult {
		var pending: [AIArticle] = []
		var cached = Set<String>()
		for article in articles {
			guard !article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				continue
			}
			if let cachedTranslation = try? await store.translation(for: article.id),
			   let titleZh = cachedTranslation.titleZh,
			   !titleZh.isEmpty,
			   AIContentHash.matchesTitleHash(cachedTranslation.contentHash, article: article) {
				cached.insert(article.id)
				continue
			}
			pending.append(article)
		}

		guard !pending.isEmpty else {
			return TitleTranslationResult(cached: cached)
		}
		let translations = try await engine.translateTitles(pending)
		let translated = Set(translations.keys)
		let failed = Set(pending.map(\.id)).subtracting(translated)
		return TitleTranslationResult(translated: translated, cached: cached, failed: failed)
	}

	@discardableResult
	func translateTitle(_ article: AIArticle) async throws -> Bool {
		let result = try await translateTitles([article])
		return !result.translated.isEmpty
	}

	func translateBody(_ article: AIArticle) async throws -> BodyTranslationResult {
		try await bodyRunner.translate(article)
	}
}
