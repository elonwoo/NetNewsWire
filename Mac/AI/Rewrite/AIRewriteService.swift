//
//  AIRewriteService.swift
//  NetNewsWire
//

import AI
import Foundation

enum AIRewriteError: Error, Sendable {
	case qualityRejected(String)
}

struct AIRewriteResult: Sendable {
	let generated: Bool
	let inputCharacters: Int?
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

	/// Returns whether a new rewrite was generated.
	@discardableResult
	func rewrite(_ article: AIArticle, fingerprintArticle: AIArticle? = nil, fullText: Bool = false, force: Bool = false) async throws -> AIRewriteResult {
		let fingerprint = fingerprintArticle ?? article
		let kind = AIRewriteKindSelector.kind(for: fingerprint).engineKind
		let baseHash = ContentFingerprint.rewrite(for: fingerprint, kind: kind)
		let expectedHash = fullText ? "ft:" + baseHash : baseHash
		let previous = try await store.rewrite(for: article.id)
		if !force, let previous, previous.contentHash == expectedHash, !previous.bodyMarkdown.isEmpty {
			return AIRewriteResult(generated: false, inputCharacters: nil)
		}

		let source = RewriteSourceBuilder.source(for: article)
		guard !source.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw AIEngineError.emptyContent
		}

		let result = try await engine.rewrite(article, kind: kind, fingerprintArticle: fingerprintArticle, fullText: fullText)
		// The engine has already stored this rewrite, so the rewrite view can
		// display it while quality validation runs. A rejected result with no
		// previous rewrite to restore is deleted below. The timeline should turn
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
				// The pane may have polled the rejected output, so tell it the
				// restored rewrite is what should be shown now.
				NotificationCenter.default.post(
					name: .aiRewriteStored,
					object: nil,
					userInfo: [AIUserInfoKey.articleID: article.id]
				)
			} else {
				// The engine persisted this output before validation. With no
				// previous rewrite to restore, remove it so a rejected result is
				// not stored as current or rendered in the pane.
				try? await store.deleteRewrite(articleID: article.id)
				NotificationCenter.default.post(
					name: .aiRewriteRemoved,
					object: nil,
					userInfo: [AIUserInfoKey.articleID: article.id]
				)
			}
			throw AIRewriteError.qualityRejected(quality.reason)
		}
		return AIRewriteResult(generated: true, inputCharacters: source.promptText.count)
	}
}
