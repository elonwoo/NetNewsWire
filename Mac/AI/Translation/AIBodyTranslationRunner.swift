//
//  AIBodyTranslationRunner.swift
//  NetNewsWire
//

import AI
import Foundation

/// Runs a body translation through the engine and keeps finished work durable.
///
/// The first attempt sends the whole article in one engine call. If that call
/// fails, the article is split into coarse segments and each successful
/// segment is stored under a synthetic article ID, so later attempts resume
/// instead of starting over.
@MainActor
final class AIBodyTranslationRunner {

	private let store: AIStore
	private let engine: AIEngine
	private let config: AIConfig

	init(store: AIStore, engine: AIEngine, config: AIConfig) {
		self.store = store
		self.engine = engine
		self.config = config
	}

	func translate(_ article: AIArticle) async throws -> BodyTranslationResult {
		let expectedHash = AIContentHash.body(for: article)
		// Body translations are never re-run automatically: readable blocks stay
		// even when the source or pipeline version changes.
		if let cached = try? await store.translation(for: article.id), !cached.blocks.isEmpty {
			return BodyTranslationResult(translation: cached, wasCached: true)
		}

		let segments = Self.segments(for: article, config: config)
		if segments.count > 1, try await hasProgress(article: article, segments: segments) {
			let translation = try await translateSegments(article, segments: segments, expectedHash: expectedHash)
			return BodyTranslationResult(translation: translation, wasCached: false)
		}

		do {
			let translation = try await engine.translateBody(article)
			return BodyTranslationResult(translation: translation, wasCached: false)
		} catch {
			guard segments.count > 1, Self.isRecoverable(error) else {
				throw error
			}
			let translation = try await translateSegments(article, segments: segments, expectedHash: expectedHash)
			return BodyTranslationResult(translation: translation, wasCached: false)
		}
	}

	/// Only failures that point at the output itself benefit from retrying in
	/// smaller pieces. Authentication, network and empty-content failures are
	/// retried as a whole by the job queue.
	static func isRecoverable(_ error: Error) -> Bool {
		if let engineError = error as? AIEngineError {
			switch engineError {
			case .incompleteTranslation, .invalidModelResponse:
				return true
			case .emptyContent:
				return false
			}
		}
		if let clientError = error as? AIClientError {
			switch clientError {
			case .truncated, .emptyContent:
				return true
			case .invalidResponse, .httpStatus, .missingContent:
				return false
			}
		}
		return false
	}
}

private extension AIBodyTranslationRunner {

	static func segments(for article: AIArticle, config: AIConfig) -> [AIBodySegment] {
		let maxBytes = max(4000, config.maxTokens * 2)
		if let html = article.contentHTML, !html.isEmpty {
			return AIBodySegmenter.segments(source: html, isHTML: true, maxBytes: maxBytes, forceSplit: true)
		}
		let text = article.contentText ?? ""
		guard !text.isEmpty else {
			return []
		}
		return AIBodySegmenter.segments(source: text, isHTML: false, maxBytes: maxBytes, forceSplit: true)
	}

	static func syntheticArticleID(articleID: String, segment: AIBodySegment) -> String {
		"\(articleID)#ai-segment-b2-\(segment.key)"
	}

	static func segmentArticle(article: AIArticle, segment: AIBodySegment) -> AIArticle {
		AIArticle(
			id: syntheticArticleID(articleID: article.id, segment: segment),
			title: article.title,
			contentHTML: segment.isHTML ? segment.content : nil,
			contentText: segment.isHTML ? nil : segment.content,
			url: article.url,
			feedID: article.feedID,
			publishedAt: article.publishedAt
		)
	}

	func hasProgress(article: AIArticle, segments: [AIBodySegment]) async throws -> Bool {
		for segment in segments {
			let segmentArticle = Self.segmentArticle(article: article, segment: segment)
			if let cached = try? await store.translation(for: segmentArticle.id),
			   !cached.blocks.isEmpty,
			   cached.contentHash == AIContentHash.body(for: segmentArticle) {
				return true
			}
		}
		return false
	}

	func translateSegments(_ article: AIArticle, segments: [AIBodySegment], expectedHash: String) async throws -> AI.Translation {
		var blocks: [TranslationBlock] = []
		var titleZh: String?
		var summaryZh: String?

		for segment in segments {
			let translation = try await translateSegment(article, segment: segment)
			for block in translation.blocks {
				blocks.append(TranslationBlock(index: blocks.count, source: block.source, target: block.target, targetHTML: block.targetHTML))
			}
			if titleZh == nil {
				titleZh = translation.titleZh
			}
			if summaryZh == nil {
				summaryZh = translation.summaryZh
			}
		}

		let now = Date()
		let translation = AI.Translation(
			articleID: article.id,
			titleZh: titleZh,
			summaryZh: summaryZh,
			blocks: blocks,
			model: config.model,
			provider: "magpie",
			contentHash: expectedHash,
			createdAt: now,
			updatedAt: now
		)
		try await store.saveTranslation(translation)
		return translation
	}

	func translateSegment(_ article: AIArticle, segment: AIBodySegment) async throws -> AI.Translation {
		let segmentArticle = Self.segmentArticle(article: article, segment: segment)
		if let cached = try? await store.translation(for: segmentArticle.id),
		   !cached.blocks.isEmpty,
		   cached.contentHash == AIContentHash.body(for: segmentArticle) {
			return cached
		}
		return try await engine.translateBody(segmentArticle)
	}
}
