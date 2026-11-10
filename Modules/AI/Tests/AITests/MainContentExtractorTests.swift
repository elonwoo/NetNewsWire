//
//  MainContentExtractorTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class MainContentExtractorTests {

	@Test func fullArticlePageDropsChromeAndComments() throws {
		let html = Self.fullArticlePage()
		let extracted = try #require(MainContentExtractor.mainContentHTML(from: html))

		#expect(extracted.contains("Main article heading"))
		#expect(extracted.contains("First body paragraph"))
		#expect(extracted.contains("Second body paragraph"))
		#expect(!extracted.contains("Site navigation"))
		#expect(!extracted.contains("Reader comment"))
		#expect(!extracted.contains("Popular sidebar link"))
		#expect(!extracted.contains("Site footer"))
	}

	@Test func pageWithoutArticleTagPicksThePostContainer() throws {
		let html = """
		<html><body>
		<div id="wrapper">
		<div class="entry-content">
		<h1>Heading without an article tag</h1>
		<p>\(Self.sentence("Body paragraph"))</p>
		<p>\(Self.sentence("Second paragraph"))</p>
		</div>
		<div class="sidebar"><p>\(Self.sentence("Sidebar noise"))</p></div>
		</div>
		</body></html>
		"""
		let extracted = try #require(MainContentExtractor.mainContentHTML(from: html))

		#expect(extracted.contains("Heading without an article tag"))
		#expect(extracted.contains("Body paragraph"))
		#expect(!extracted.contains("Sidebar noise"))
	}

	@Test func articleContainerWinsOverALongerResponseList() throws {
		let articleText = Self.sentence("Article body", words: 20)
		let responseText = Self.sentence("Reader response", words: 100)
		let html = """
		<html><body>
		<article><p>\(articleText)</p></article>
		<div id="responses"><p>\(responseText)</p></div>
		</body></html>
		"""
		let extracted = try #require(MainContentExtractor.mainContentHTML(from: html))

		#expect(extracted.contains("Article body"))
		#expect(!extracted.contains("Reader response"))
	}

	@Test func scriptOnlyPageReturnsNil() {
		let html = """
		<html><head><style>body { color: red; }</style></head>
		<body><script>document.write("<p>not content</p>")</script></body></html>
		"""
		#expect(MainContentExtractor.mainContentHTML(from: html) == nil)
	}

	@Test func pageDuplicateOfTheTeaserIsStillExtracted() throws {
		let teaser = "Teaser text that repeats the feed summary."
		let html = """
		<html><body><article><p>\(teaser)</p></article></body></html>
		"""
		let extracted = try #require(MainContentExtractor.mainContentHTML(from: html))

		#expect(extracted == "<p>\(teaser)</p>")
		#expect(HTMLSourceBlocks.plainText(extracted) == teaser)
	}

	@Test func commentsOnlyPageReturnsNil() {
		let html = """
		<html><body>
		<section class="comments">
		<p>\(Self.sentence("Reader comment one"))</p>
		<p>\(Self.sentence("Reader comment two"))</p>
		<p>\(Self.sentence("Reader comment three"))</p>
		</section>
		</body></html>
		"""
		#expect(MainContentExtractor.mainContentHTML(from: html) == nil)
	}

	@Test func footerOnlyPageReturnsNil() {
		let html = """
		<html><body>
		<div id="site-footer">
		<p>\(Self.sentence("Footer link one"))</p>
		<p>\(Self.sentence("Footer link two"))</p>
		<p>\(Self.sentence("Footer link three"))</p>
		</div>
		</body></html>
		"""
		#expect(MainContentExtractor.mainContentHTML(from: html) == nil)
	}

	@Test func newsletterCopyIsNotPartOfTheExtraction() throws {
		let articleText = Self.sentence("Teaser paragraph", words: 55)
		let newsletterText = Self.sentence("Newsletter copy", words: 65)
		let html = """
		<html><body>
		<article><h1>Short post</h1><p>\(articleText)</p></article>
		<section class="newsletter"><p>\(newsletterText)</p></section>
		</body></html>
		"""
		let extracted = try #require(MainContentExtractor.mainContentHTML(from: html))

		#expect(extracted.contains("Teaser paragraph"))
		#expect(!extracted.contains("Newsletter copy"))
	}
}

private extension MainContentExtractorTests {

	static func fullArticlePage() -> String {
		"""
		<html><head><title>Example</title></head><body>
		<header id="site-header"><h1>Example site</h1></header>
		<nav><a href="/one">Site navigation one</a> <a href="/two">Site navigation two</a></nav>
		<div id="page">
		<article class="post-content">
		<h1>Main article heading</h1>
		<p>\(sentence("First body paragraph"))</p>
		<p>\(sentence("Second body paragraph"))</p>
		</article>
		<section class="comments">
		<p>\(sentence("Reader comment"))</p>
		<p>\(sentence("Another reader comment"))</p>
		</section>
		<aside class="sidebar"><p><a href="/popular">Popular sidebar link</a></p></aside>
		</div>
		<footer><p>Site footer copyright notice</p></footer>
		</body></html>
		"""
	}

	static func sentence(_ prefix: String, words: Int = 80) -> String {
		prefix + " " + String(repeating: "content ", count: words)
	}
}
