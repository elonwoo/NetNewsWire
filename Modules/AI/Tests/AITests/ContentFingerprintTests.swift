//
//  ContentFingerprintTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class ContentFingerprintTests {

	// MARK: - Legacy goldens

	@Test func legacyRewriteGoldenValues() {
		let htmlOnly = AIArticle(id: "a", title: "Title", contentHTML: "<p>Hello &amp; world</p>")
		#expect(ContentFingerprint.legacyRewrite(for: htmlOnly) == "3020676e3ebbeda40cb91b84ff5436d6680e2b417b32b997260929f51c65816b")

		let textWins = AIArticle(id: "b", title: "Title", contentHTML: "<p>x</p>", contentText: "Hello & world")
		#expect(ContentFingerprint.legacyRewrite(for: textWins) == "d11d5254a40ca3c09b4b59b20d6cf16d9c2fb380b002f1f11273b0faa5451519")

		let emptyText = AIArticle(id: "c", title: "Title", contentHTML: "<p>x</p>", contentText: "")
		#expect(ContentFingerprint.legacyRewrite(for: emptyText) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	}

	@Test func legacyBodyGoldenValues() {
		let htmlOnly = AIArticle(id: "a", title: "Title", contentHTML: "<p>Hello &amp; world</p>")
		#expect(ContentFingerprint.legacyBody(for: htmlOnly) == "3020676e3ebbeda40cb91b84ff5436d6680e2b417b32b997260929f51c65816b")

		let textWins = AIArticle(id: "b", title: "Title", contentHTML: "", contentText: "Hello & world")
		#expect(ContentFingerprint.legacyBody(for: textWins) == "d11d5254a40ca3c09b4b59b20d6cf16d9c2fb380b002f1f11273b0faa5451519")

		let empty = AIArticle(id: "c", title: "Title")
		#expect(ContentFingerprint.legacyBody(for: empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	}

	// MARK: - Determinism

	@Test func rewriteFingerprintIsStable() {
		let article = AIArticle(id: "a", title: "Title", contentHTML: "<p>Body <a href=\"https://example.com\">link</a></p>")
		let first = ContentFingerprint.rewrite(for: article, kind: .article)
		let second = ContentFingerprint.rewrite(for: article, kind: .article)

		#expect(first == second)
		#expect(first.hasPrefix("r2:"))
	}

	@Test func rewriteFingerprintChangesWithKind() {
		let article = AIArticle(id: "a", title: "Title", contentHTML: "<p>Body</p>")
		let articleHash = ContentFingerprint.rewrite(for: article, kind: .article)
		let paperHash = ContentFingerprint.rewrite(for: article, kind: .paper)

		#expect(articleHash != paperHash)
	}

	@Test func rewriteCanonicalSortsLinksAndKeepsImageOrder() {
		let first = RewriteSource(
			promptText: "Body",
			plainText: "Body",
			images: [HTMLImageRef(url: "https://example.com/a.png")],
			links: [
				RewriteLink(label: "B", url: "https://b.example"),
				RewriteLink(label: "A", url: "https://a.example")
			]
		)
		let second = RewriteSource(
			promptText: "Body",
			plainText: "Body",
			images: [HTMLImageRef(url: "https://example.com/a.png")],
			links: [
				RewriteLink(label: "A", url: "https://a.example"),
				RewriteLink(label: "B", url: "https://b.example"),
				RewriteLink(label: "A duplicate", url: "https://a.example")
			]
		)
		#expect(ContentFingerprint.canonicalRewrite(kind: .article, title: "T", source: first)
			== ContentFingerprint.canonicalRewrite(kind: .article, title: "T", source: second))

		let swappedImages = RewriteSource(
			promptText: "Body",
			plainText: "Body",
			images: [
				HTMLImageRef(url: "https://example.com/b.png"),
				HTMLImageRef(url: "https://example.com/a.png")
			],
			links: []
		)
		let originalImages = RewriteSource(
			promptText: "Body",
			plainText: "Body",
			images: [
				HTMLImageRef(url: "https://example.com/a.png"),
				HTMLImageRef(url: "https://example.com/b.png")
			],
			links: []
		)
		#expect(ContentFingerprint.canonicalRewrite(kind: .article, title: "T", source: swappedImages)
			!= ContentFingerprint.canonicalRewrite(kind: .article, title: "T", source: originalImages))
	}

	@Test func fingerprintsDoNotCrossContaminate() {
		let article = AIArticle(id: "a", title: "Title", contentHTML: "<p>Body</p>", contentText: "Body")

		let title = ContentFingerprint.title(for: article)
		let body = ContentFingerprint.body(for: article)
		let rewrite = ContentFingerprint.rewrite(for: article, kind: .article)

		#expect(!title.hasPrefix("r2:"))
		#expect(!title.hasPrefix("b2:"))
		#expect(body.hasPrefix("b2:"))
		#expect(rewrite.hasPrefix("r2:"))
		#expect(title != body)
		#expect(body != rewrite)
	}

	@Test func bodyUsesHTMLWhenNonBlank() {
		let article = AIArticle(id: "a", title: "Title", contentHTML: "<p>Body</p>", contentText: "Other")
		#expect(ContentFingerprint.body(for: article) == "b2:" + ContentFingerprint.sha256Hex("<p>Body</p>"))

		let blankHTML = AIArticle(id: "b", title: "Title", contentHTML: "   ", contentText: "Other")
		#expect(ContentFingerprint.body(for: blankHTML) == "b2:" + ContentFingerprint.sha256Hex("Other"))
	}
}
