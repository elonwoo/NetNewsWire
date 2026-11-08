//
//  AIContentHash.swift
//  NetNewsWire
//

import AI
import CryptoKit
import Foundation

/// Content hashes must match the ones the engine stores so that a cached
/// translation or rewrite can be recognised as current.
enum AIContentHash {

	/// Hash used for title translations and rewrites: `contentText`, falling
	/// back to `contentHTML`, then the title.
	static func titleOrRewrite(for article: AIArticle) -> String {
		sha256Hex(article.contentText ?? article.contentHTML ?? article.title)
	}

	/// Hash used for body translations: HTML when present, otherwise text.
	static func body(for article: AIArticle) -> String {
		if let html = article.contentHTML, !html.isEmpty {
			return sha256Hex(html)
		}
		return sha256Hex(article.contentText ?? "")
	}

	/// A title translation may have been written by either a title job or a
	/// body translation, which use different hashes for the same content.
	static func matchesTitleHash(_ stored: String, article: AIArticle) -> Bool {
		stored == titleOrRewrite(for: article) || stored == body(for: article)
	}

	static func sha256Hex(_ text: String) -> String {
		let digest = SHA256.hash(data: Data(text.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}
