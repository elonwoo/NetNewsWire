//
//  RewriteOutputNormalizerTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class RewriteOutputNormalizerTests {

	private let first = HTMLImageRef(url: "https://example.com/a.png", alt: "A", caption: "Caption A")
	private let second = HTMLImageRef(url: "https://example.com/b.png", alt: "B")

	@Test func restoresTokensAndBackfillsMissingImages() {
		let output = "正文 {{img:0}} 结束"
		let body = RewriteOutputNormalizer.normalize(output, images: [first, second])

		#expect(body.contains("![A](https://example.com/a.png)"))
		#expect(body.contains("![B](https://example.com/b.png)"))
		#expect(body.contains("Caption A"))
		#expect(!body.contains("{{img:"))
	}

	@Test func duplicateTokenIsRestoredOnlyOnce() {
		let body = RewriteOutputNormalizer.normalize("{{img:0}} 中 {{img:0}}", images: [first])

		#expect(body.components(separatedBy: "![A]").count - 1 == 1)
	}

	@Test func unknownTokenIsDeleted() {
		let body = RewriteOutputNormalizer.normalize("正文 {{img:9}} 结束", images: [first])

		#expect(!body.contains("{{img:9}}"))
		#expect(body.contains("![A](https://example.com/a.png)"))
	}

	@Test func completeTagsBecomeMarkdown() {
		let output = """
		<p>Hello</p><strong>bold</strong><br>line<a href="https://example.com">link</a>
		"""
		let body = RewriteOutputNormalizer.normalize(output, images: [])

		#expect(!body.contains("<"))
		#expect(body.contains("Hello"))
		#expect(body.contains("**bold**"))
		#expect(body.contains("[link](https://example.com)"))
	}

	@Test func danglingTagsAreRemoved() {
		let output = #"Text <img src="x" and <p"#
		let body = RewriteOutputNormalizer.normalize(output, images: [])

		#expect(!body.contains("<"))
		#expect(body.contains("Text"))
	}

	@Test func escapedTagsAreHandledUpToTwoLevels() {
		let single = RewriteOutputNormalizer.normalize("&lt;p&gt;Hello&lt;/p&gt;", images: [])
		#expect(single == "Hello")

		let double = RewriteOutputNormalizer.normalize("&amp;lt;strong&amp;gt;bold&amp;lt;/strong&amp;gt;", images: [])
		#expect(double == "**bold**")

		let notATag = RewriteOutputNormalizer.normalize("a &lt; b", images: [])
		#expect(notATag.contains("&lt;"))
	}

	@Test func autolinksAndComparisonsSurvive() {
		let output = "See <https://example.com> and a < b, <5"
		let body = RewriteOutputNormalizer.normalize(output, images: [])

		#expect(body.contains("<https://example.com>"))
		#expect(body.contains("a < b"))
		#expect(body.contains("<5"))
	}

	@Test func codeFenceIsProtected() {
		let output = "```\n{{img:0}} <p>\n```"
		let body = RewriteOutputNormalizer.normalize(output, images: [first])

		#expect(body.contains("{{img:0}} <p>"))
		#expect(body.contains("![A](https://example.com/a.png)"))
	}

	@Test func removesLeadingH1AndHorizontalRules() {
		let output = "# 一级标题\n\n正文\n\n---\n\n更多"
		let body = RewriteOutputNormalizer.normalize(output, images: [])

		#expect(!body.contains("一级标题"))
		#expect(!body.contains("---"))
		#expect(body.contains("正文"))
	}

	@Test func tagEndScanningIsQuoteAware() {
		let output = #"<a title="a > b" href="https://example.com">x</a>"#
		let body = RewriteOutputNormalizer.normalize(output, images: [])

		#expect(body == "[x](https://example.com)")
	}

	@Test func noHTMLTagsRemainInMixedOutput() {
		let output = """
		<div class="x"><h2>标题</h2><p>正文 <img src="https://example.com/a.png"></p></div>
		"""
		let body = RewriteOutputNormalizer.normalize(output, images: [])

		#expect(!body.contains("<div"))
		#expect(!body.contains("<h2"))
		#expect(!body.contains("<p"))
		#expect(body.contains("标题"))
	}
}
