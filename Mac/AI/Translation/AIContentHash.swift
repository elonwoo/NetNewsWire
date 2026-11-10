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

	private static let bodyLengthCache = BodyLengthCache()

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
		if requiresFullTextRefresh(storedHash: stored, article: article) {
			return .contentChanged
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

	/// A short article rewritten before full-text fetching is untrusted even
	/// when its feed-based hash still matches. Every short-body article must
	/// either gain an `ft:` rewrite or lose the old row.
	static func requiresFullTextRefresh(storedHash: String, article: AIArticle) -> Bool {
		guard AIRewriteKindSelector.kind(for: article) == .article else {
			return false
		}
		return bodyCharacterCount(for: article) < AIFullTextFetcher.summaryCharacterLimit
			&& !storedHash.hasPrefix("ft:")
	}

	/// Body length is parsed from HTML, so cache it by article id, content
	/// fingerprint and text fallback. The fallback is part of the key because a
	/// blank HTML body is measured from `contentText` instead. The first lookup
	/// per content still runs on the caller's actor, which is the main actor for
	/// the pane and planner.
	static func bodyCharacterCount(for article: AIArticle) -> Int {
		let key = "\(article.id)|\(ContentFingerprint.body(for: article))|\(article.contentText ?? "")" as NSString
		if let cached = bodyLengthCache.value(for: key) {
			return cached
		}
		let count = AIFullTextFetcher.bodyCharacterCount(for: article)
		bodyLengthCache.insert(count, for: key)
		return count
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

/// `NSCache` is thread-safe but not `Sendable`; this wrapper keeps the shared
/// cache usable from both the main actor and concurrent callers.
private final class BodyLengthCache: @unchecked Sendable {

	private let cache = NSCache<NSString, NSNumber>()

	func value(for key: NSString) -> Int? {
		cache.object(forKey: key)?.intValue
	}

	func insert(_ value: Int, for key: NSString) {
		cache.setObject(NSNumber(value: value), forKey: key)
	}
}
