//
//  AIContentHash.swift
//  NetNewsWire
//

import AI
import Foundation

/// How a stored rewrite relates to the current article and pipeline.
enum AIRewriteState: Equatable {
	case missing
	case current
	/// Stored by the pre-pipeline rewrite algorithm. Shown as stale but never
	/// re-run automatically.
	case pipelineOutdated
	case contentChanged
}

/// Content hashes must match the ones the engine stores so that a cached
/// translation or rewrite can be recognised as current.
///
/// There is deliberately no combined title/rewrite entry point: title
/// translations, rewrites and body translations each have their own hash and
/// must never overwrite one another.
enum AIContentHash {

	static func title(for article: AIArticle) -> String {
		ContentFingerprint.title(for: article)
	}

	static func body(for article: AIArticle) -> String {
		ContentFingerprint.body(for: article)
	}

	static func rewrite(for article: AIArticle) -> String {
		ContentFingerprint.rewrite(for: article, kind: AIRewriteKindSelector.kind(for: article).engineKind)
	}

	static func legacyRewrite(for article: AIArticle) -> String {
		ContentFingerprint.legacyRewrite(for: article)
	}

	/// A title translation may have been written by a title job, an older body
	/// translation, or the current body pipeline. It is never written by a
	/// rewrite, so `r2:` hashes are not accepted.
	static func matchesTitleHash(_ stored: String, article: AIArticle) -> Bool {
		stored == ContentFingerprint.title(for: article)
			|| stored == ContentFingerprint.legacyBody(for: article)
			|| stored == ContentFingerprint.body(for: article)
	}

	static func rewriteState(stored: String?, article: AIArticle) -> AIRewriteState {
		guard let stored, !stored.isEmpty else {
			return .missing
		}
		let normalized = normalizedRewriteHash(stored)
		if normalized == rewrite(for: article) {
			return .current
		}
		if normalized == ContentFingerprint.legacyRewrite(for: article) {
			return .pipelineOutdated
		}
		return .contentChanged
	}

	/// Full-text rewrites carry an `ft:` provenance prefix. Every automatic
	/// comparison ignores it so the rewrite stays current.
	static func normalizedRewriteHash(_ hash: String) -> String {
		hash.hasPrefix("ft:") ? String(hash.dropFirst(3)) : hash
	}

	/// Legacy and pipeline-outdated rewrites are treated as up to date by every
	/// automatic path; only content changes or a missing rewrite are queued.
	static func isRewriteUpToDate(stored: String?, article: AIArticle) -> Bool {
		switch rewriteState(stored: stored, article: article) {
		case .current, .pipelineOutdated:
			return true
		case .missing, .contentChanged:
			return false
		}
	}

	static func sha256Hex(_ text: String) -> String {
		ContentFingerprint.sha256Hex(text)
	}
}
