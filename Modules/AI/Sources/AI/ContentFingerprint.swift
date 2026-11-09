//
//  ContentFingerprint.swift
//  AI
//

import CryptoKit
import Foundation

/// The only place that defines the content hashes stored with translations and
/// rewrites.
///
/// The three hashes are intentionally separate entry points so no call site can
/// accidentally write one kind of hash where another is expected:
///
/// - `title` keeps the original title-translation algorithm, unprefixed.
/// - `rewrite` is versioned with `r2:` because the rewrite pipeline changed.
/// - `body` is versioned with `b2:` because the translation pipeline changed.
///
/// The `legacy*` functions reproduce the pre-pipeline algorithms so existing
/// rows can be classified instead of being mistaken for changed content.
public enum ContentFingerprint {

	// MARK: - Current algorithms

	/// Title translations keep the old algorithm and gain no version prefix.
	public static func title(for article: AIArticle) -> String {
		sha256Hex(article.contentText ?? article.contentHTML ?? article.title)
	}

	/// Rewrite fingerprint. Built from the visible source only, never from the
	/// raw article HTML, so markup-only changes do not invalidate a rewrite.
	public static func rewrite(for article: AIArticle, kind: RewriteKind) -> String {
		let source = RewriteSourceBuilder.source(for: article)
		return "r2:" + sha256Hex(canonicalRewrite(kind: kind, title: article.title, source: source))
	}

	/// Body translation fingerprint. HTML wins whenever it is non-blank.
	public static func body(for article: AIArticle) -> String {
		if let html = article.contentHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return "b2:" + sha256Hex(html)
		}
		return "b2:" + sha256Hex(article.contentText ?? "")
	}

	// MARK: - Legacy algorithms

	public static func legacyRewrite(for article: AIArticle) -> String {
		sha256Hex(article.contentText ?? article.contentHTML ?? article.title)
	}

	public static func legacyBody(for article: AIArticle) -> String {
		if let html = article.contentHTML, !html.isEmpty {
			return sha256Hex(html)
		}
		return sha256Hex(article.contentText ?? "")
	}

	// MARK: - Canonical serialization

	/// Deterministic, length-prefixed serialization. Nothing iterates a `Set` or
	/// a `Dictionary`: images keep document order and links are sorted by URL.
	static func canonicalRewrite(kind: RewriteKind, title: String, source: RewriteSource) -> String {
		var result = ""
		result += field("kind", kind.rawValue)
		result += field("title", title)
		result += field("promptText", source.promptText)
		result += field("imageCount", String(source.images.count))
		for image in source.images {
			result += field("imageUrl", image.url)
			result += field("imageAlt", image.alt)
			result += field("imageCaption", image.caption ?? "")
		}

		let orderedLinks = source.links.enumerated()
			.sorted { lhs, rhs in
				if lhs.element.url != rhs.element.url {
					return lhs.element.url < rhs.element.url
				}
				if lhs.element.label != rhs.element.label {
					return lhs.element.label < rhs.element.label
				}
				return lhs.offset < rhs.offset
			}
			.map(\.element)
		var seenURLs = Set<String>()
		var uniqueLinks: [RewriteLink] = []
		for link in orderedLinks where !seenURLs.contains(link.url) {
			seenURLs.insert(link.url)
			uniqueLinks.append(link)
		}

		result += field("linkCount", String(uniqueLinks.count))
		for link in uniqueLinks {
			result += field("linkUrl", link.url)
			result += field("linkLabel", link.label)
		}
		return result
	}

	private static func field(_ name: String, _ value: String) -> String {
		"\(name).\(value.utf8.count):\(value)"
	}

	// MARK: - Hashing

	public static func sha256Hex(_ text: String) -> String {
		let digest = SHA256.hash(data: Data(text.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}
