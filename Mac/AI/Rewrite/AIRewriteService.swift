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
		let kind = AIRewriteKindSelector.kind(for: article).engineKind
		let expectedHash = ContentFingerprint.rewrite(for: article, kind: kind)
		let previous = try await store.rewrite(for: article.id)
		if let previous, previous.contentHash == expectedHash, !previous.bodyMarkdown.isEmpty {
			return false
		}

		let source = RewriteSourceBuilder.source(for: article)
		guard !source.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw AIEngineError.emptyContent
		}

		let result = try await engine.rewrite(article, kind: kind)
		// The engine has already stored this rewrite, so the rewrite view can display
		// it even if quality validation rejects it below. The timeline should turn
		// green now rather than wait for the job to finish or the app to restart.
		NotificationCenter.default.post(
			name: .aiRewriteStored,
			object: nil,
			userInfo: [AIUserInfoKey.articleID: article.id]
		)
		let quality = AIRewriteQualityValidator.evaluate(sourceText: source.plainText, body: result.bodyMarkdown)
		guard quality.ok else {
			if let previous, !previous.bodyMarkdown.isEmpty {
				try? await store.saveRewrite(previous)
			}
			throw AIRewriteError.qualityRejected(quality.reason)
		}
		return true
	}
}
