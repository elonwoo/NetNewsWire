//
//  AIRewriteService.swift
//  NetNewsWire
//

import AI
import Foundation

enum AIRewriteError: Error, Sendable {
	case qualityRejected(String)
}

/// Generates a Chinese rewrite for an article and validates it before the job
/// is reported as complete.
///
/// The engine persists the model output before returning, so a rejected
/// rewrite is replaced with the previous valid one when there is one. A later
/// retry overwrites it with a passing result.
@MainActor
final class AIRewriteService {

	private let store: AIStore
	private let engine: AIEngine

	init(store: AIStore, engine: AIEngine) {
		self.store = store
		self.engine = engine
	}

	/// Returns true when a new rewrite was generated.
	@discardableResult
	func rewrite(_ article: AIArticle) async throws -> Bool {
		let expectedHash = AIContentHash.titleOrRewrite(for: article)
		let previous = try await store.rewrite(for: article.id)
		if let previous, previous.contentHash == expectedHash, !previous.bodyMarkdown.isEmpty {
			return false
		}

		let source = article.contentText ?? article.contentHTML ?? ""
		guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw AIEngineError.emptyContent
		}

		let kind = AIRewriteKindSelector.kind(for: article).engineKind
		let result = try await engine.rewrite(article, kind: kind)
		let quality = AIRewriteQualityValidator.evaluate(sourceText: source, body: result.bodyMarkdown)
		guard quality.ok else {
			if let previous, !previous.bodyMarkdown.isEmpty {
				try? await store.saveRewrite(previous)
			}
			throw AIRewriteError.qualityRejected(quality.reason)
		}
		return true
	}
}
