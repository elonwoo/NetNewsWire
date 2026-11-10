//
//  HTMLSourceBlocksTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class HTMLSourceBlocksTests {

	@Test func topLevelAndContainerSplitting() {
		let html = """
		<div><p>One</p><section><p>Two</p></section><p>Three</p></div>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)

		#expect(blocks.map(\.text) == ["One", "Two", "Three"])
		#expect(blocks.map(\.tag) == ["p", "p", "p"])
		#expect(blocks.allSatisfy { $0.kind == .text })
	}

	@Test func nestedListProducesSingleOuterBlock() {
		let html = """
		<ul><li>Outer<ul><li>Inner one</li><li>Inner two</li></ul></li><li>Second</li></ul>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)

		#expect(blocks.count == 2)
		#expect(blocks[0].tag == "li")
		#expect(blocks[0].text == "Outer\n  Inner one\n  Inner two")
		#expect(blocks[0].html.contains("<ul><li>Inner one</li>"))
		#expect(blocks[1].text == "Second")
	}

	@Test func paragraphWithImageExtractsImageAndIsNotTranslatable() throws {
		let html = """
		<p><img src="https://example.com/a.png" alt="A"></p>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)
		let block = try #require(blocks.first)

		#expect(block.images == [HTMLImageRef(url: "https://example.com/a.png", alt: "A")])
		#expect(block.text.isEmpty)
		#expect(!block.isTranslatable)
	}

	@Test func figureWithCaptionIsTranslatable() throws {
		let html = """
		<figure><img src="https://example.com/a.png" alt="A"><figcaption>Caption text</figcaption></figure>
		"""
		let block = try #require(HTMLSourceBlocks.blocks(html).first)

		#expect(block.kind == .text)
		#expect(block.text == "Caption text")
		#expect(block.images.first?.caption == "Caption text")
		#expect(block.isTranslatable)
	}

	@Test func preProducesNoSlots() {
		let html = """
		<p>Use <code>let x</code> here</p><pre><code class="language-swift">let x = 1</code></pre>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)
		let plans = TranslationBlockPlanner.plans(from: blocks)

		#expect(blocks[1].kind == .code)
		#expect(!plans[1].isTranslatable)
		#expect(plans[1].slotCount == 0)
		#expect(!plans[1].promptText.contains("let x"))
		#expect(plans[0].slotCount == 2)
		#expect(plans[0].templateHTML.contains("<code>let x</code>"))
		#expect(!plans[0].promptText.contains("let x"))
		#expect(plans[0].slotTexts.allSatisfy { !$0.contains("let x") })
	}

	@Test func paragraphWithOnlyLinkTextIsTranslatable() throws {
		let samples = [
			"<p><a href=\"/a\">Tool</a>: <a href=\"/b\">Yonkers Rises</a></p>",
			"<p><a href=\"/a\">Tool:</a> <a href=\"/b\">Yonkers Rises</a></p>"
		]
		for html in samples {
			let block = try #require(HTMLSourceBlocks.blocks(html).first)
			let plan = try #require(TranslationBlockPlanner.plans(from: [block]).first)

			#expect(plan.slotCount > 1)
			#expect(plan.isTranslatable)
			#expect(plan.promptText.contains("{{t0}}Tool"))
		}
	}

	@Test func paragraphWithTextOutsideLinksStaysTranslatable() throws {
		let html = """
		<p>The <a href="/a">Tool</a> ships with <a href="/b">Yonkers Rises</a> inside.</p>
		"""
		let block = try #require(HTMLSourceBlocks.blocks(html).first)
		let plan = try #require(TranslationBlockPlanner.plans(from: [block]).first)

		#expect(plan.isTranslatable)
		#expect(plan.slotCount == 5)
		#expect(plan.slotTexts == ["The", "Tool", "ships with", "Yonkers Rises", "inside."])
		#expect(plan.promptText == "{{t0}}The {{t1}}Tool{{t2}} ships with {{t3}}Yonkers Rises{{t4}} inside.")
	}

	@Test func tableCellsBecomeSlots() throws {
		let html = """
		<table><tr><th>Name</th><th>Value</th></tr><tr><td>Alpha</td><td>1</td></tr></table>
		"""
		let block = try #require(HTMLSourceBlocks.blocks(html).first)
		let plan = try #require(TranslationBlockPlanner.plans(from: [block]).first)

		#expect(block.kind == .table)
		#expect(block.text == "Name | Value\nAlpha | 1")
		#expect(plan.slotCount == 4)
		#expect(plan.templateHTML.contains("{{t0}}"))
		#expect(!plan.templateHTML.contains("Name"))
		#expect(!plan.templateHTML.contains("Alpha"))
		#expect(plan.promptText == "{{t0}}Name | {{t1}}Value\n{{t2}}Alpha | {{t3}}1")
	}

	@Test func resolvesImageURLsAndDropsUnsafeOnes() {
		let html = """
		<p><img src="/a.png" alt="A"></p>
		<p><img data-src="//cdn.example.com/b.png" alt="B"></p>
		<p><img srcset="https://cdn.example.com/c.png 1x, https://cdn.example.com/d.png 2x"></p>
		<p><img src="javascript:alert(1)" alt="bad"></p>
		<p><img src="data:image/png;base64,AAAA" alt="bad"></p>
		"""
		let blocks = HTMLSourceBlocks.blocks(html, baseURL: URL(string: "https://example.com/post/1"))
		let urls = blocks.flatMap(\.images).map(\.url)

		#expect(urls == [
			"https://example.com/a.png",
			"https://cdn.example.com/b.png",
			"https://cdn.example.com/c.png"
		])
	}

	@Test func imageRefFallsBackPastUnusableSources() {
		let html = """
		<p><img src="data:image/gif;base64,AAAA" data-src="https://cdn.example.com/real.jpg" alt="A"></p>
		<p><img src="javascript:alert(1)" data-src="https://cdn.example.com/from-js.jpg" alt="B"></p>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)
		let urls = blocks.flatMap(\.images).map(\.url)

		#expect(urls == [
			"https://cdn.example.com/real.jpg",
			"https://cdn.example.com/from-js.jpg"
		])
	}

	@Test func imageRefFallsBackToAbsoluteCandidateWithoutBaseURL() {
		let html = """
		<p><img src="/relative.png" data-src="https://cdn.example.com/absolute.png" alt="A"></p>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)
		let urls = blocks.flatMap(\.images).map(\.url)

		#expect(urls == ["https://cdn.example.com/absolute.png"])
	}

	@Test func unclosedTagsAndComparisonsStayPlainText() {
		let html = """
		<p>First paragraph
		<p>Second paragraph <b>bold text
		<p>Third with a < b and <5 comparison.
		"""
		let blocks = HTMLSourceBlocks.blocks(html)

		#expect(blocks.map(\.text) == [
			"First paragraph",
			"Second paragraph bold text",
			"Third with a < b and <5 comparison."
		])
	}

	@Test func malformedInputNeverLeaksTagsIntoText() {
		let html = "<div><p>Hello <span>world</p>"
		let blocks = HTMLSourceBlocks.blocks(html)

		#expect(!blocks.isEmpty)
		for block in blocks {
			#expect(!block.text.contains("<"))
			#expect(!block.text.contains(">"))
		}
	}

	@Test func numberingIsContiguousAndMediaOccupiesAnIndex() {
		let html = """
		<p>One</p><img src="https://example.com/x.png" alt="X"><p>Two</p>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)

		#expect(blocks.map(\.index) == [0, 1, 2])
		#expect(blocks[1].kind == .media)
	}

	@Test func emptyInputReturnsNoBlocks() {
		#expect(HTMLSourceBlocks.blocks("").isEmpty)
		#expect(HTMLSourceBlocks.blocks("   \n\t  ").isEmpty)
	}

	@Test func decodesEntitiesInTextOnly() throws {
		let block = try #require(HTMLSourceBlocks.blocks("<p>Tom &amp; Jerry &lt;3 caf&eacute; &#8212; done</p>").first)

		#expect(block.text == "Tom & Jerry <3 café — done")
		#expect(block.html.contains("&amp;"))
	}

	@Test func sanitizerDropsSelfClosingScriptAndEscapesAttributes() {
		let html = #"<pre><script/>window.__pwned=1;//<a title="</script>">x</a></pre>"#
		let joined = HTMLSourceBlocks.blocks(html).map(\.html).joined()

		#expect(joined == "<pre></pre>")
		#expect(!joined.lowercased().contains("<script"))
		#expect(!joined.lowercased().contains("</script"))
		#expect(!joined.contains("window.__pwned"))
	}

	@Test func sanitizerDropsSelfClosingStyle() {
		let html = "<style/>@import url(https://evil.example/x.css);</style><p>ok</p>"
		let joined = HTMLSourceBlocks.blocks(html).map(\.html).joined()

		#expect(!joined.lowercased().contains("<style"))
		#expect(!joined.contains("@import"))
		#expect(joined.contains("ok"))
	}

	@Test func sanitizerEscapesAttributeValues() {
		let html = #"<p><a href="https://example.com/?a=1&b=2" title="a<b>c&d">x</a><img src="https://example.com/x.png" alt="1<2>3&4"></p>"#
		let joined = HTMLSourceBlocks.blocks(html).map(\.html).joined()

		#expect(joined.contains("title=\"a&lt;b&gt;c&amp;d\""))
		#expect(joined.contains("href=\"https://example.com/?a=1&amp;b=2\""))
		#expect(joined.contains("alt=\"1&lt;2&gt;3&amp;4\""))
		#expect(!joined.contains("a<b>c"))
	}

	@Test func cleaningRemovesActiveContent() {
		let html = """
		<p onclick="alert(1)" style="color:red" class="x">Safe text</p>
		<script>alert('x')</script>
		<style>p{color:red}</style>
		<a href="javascript:alert(1)" title="ok">bad link</a>
		<a href="https://example.com/safe" onclick="x">safe link</a>
		<img src="javascript:alert(1)" alt="x">
		<img src="data:image/png;base64,AAAA" alt="y">
		<noscript>no script</noscript>
		<iframe src="https://evil.example">frame</iframe>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)
		let joinedHTML = blocks.map(\.html).joined()
		let joinedText = blocks.map(\.text).joined(separator: "\n")
		let forbidden = ["script", "<style", "javascript:", "onclick", "style=", "class=\"x\"", "data:image", "<iframe", "noscript", "<script"]

		for value in forbidden {
			#expect(!joinedHTML.lowercased().contains(value.lowercased()))
			#expect(!joinedText.lowercased().contains(value.lowercased()))
		}
		#expect(joinedText.contains("Safe text"))
		#expect(joinedText.contains("safe link"))
	}

	@Test func cleaningRejectsObfuscatedJavascriptSchemes() {
		let html = """
		<a href="javascript&colon;alert(1)">one</a>
		<a href="java&#9;script:alert(1)">two</a>
		<a href="javascript&#58alert(1)">three</a>
		<a href="javascript&#0000058alert(1)">four</a>
		<a href="&#106avascript&#58alert(1)">five</a>
		<a href="vbscript&#58msgbox(1)">six</a>
		<a href="data&#58text/html;base64,AAAA">seven</a>
		<a href="java&#9script:alert(1)">eight</a>
		<a href="java&#9script&#58;alert(1)">nine</a>
		<img src="javascript&#58alert(1)" alt="x">
		"""
		let blocks = HTMLSourceBlocks.blocks(html)
		let joinedHTML = blocks.map(\.html).joined().lowercased()
		let joinedText = blocks.map(\.text).joined(separator: "\n")

		#expect(!joinedHTML.contains("javascript"))
		#expect(!joinedHTML.contains("vbscript"))
		#expect(!joinedHTML.contains("data:"))
		#expect(!joinedHTML.contains("&colon;"))
		#expect(!joinedHTML.contains("href="))
		#expect(!joinedHTML.contains("src="))
		#expect(joinedText.contains("one"))
		#expect(joinedText.contains("nine"))
	}

	@Test func youTubeIframeBecomesNoCookieEmbed() {
		let html = """
		<p>Before</p><iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ" width="560" height="315" title="Video" frameborder="0" allowfullscreen></iframe><p>After</p>
		"""
		let blocks = HTMLSourceBlocks.blocks(html)
		let joinedHTML = blocks.map(\.html).joined()

		#expect(joinedHTML.contains("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"))
		#expect(!joinedHTML.contains("www.youtube.com/embed"))
		#expect(joinedHTML.contains("width=\"560\""))
		#expect(joinedHTML.contains("height=\"315\""))
		#expect(joinedHTML.contains("allowfullscreen"))
		#expect(joinedHTML.contains("</iframe>"))
		#expect(blocks.map(\.text).joined(separator: "\n").contains("Before"))
		#expect(blocks.map(\.text).joined(separator: "\n").contains("After"))
	}

	@Test func nonYouTubeIframesAreDropped() {
		let html = """
		<p>Before</p><iframe src="https://player.vimeo.com/video/123"></iframe><iframe src="https://example.com/frame"></iframe><iframe src="javascript:alert(1)"></iframe><iframe src="javascript&#58alert(1)"></iframe><p>After</p>
		"""
		let joinedHTML = HTMLSourceBlocks.blocks(html).map(\.html).joined().lowercased()

		#expect(!joinedHTML.contains("<iframe"))
		#expect(!joinedHTML.contains("vimeo"))
		#expect(!joinedHTML.contains("javascript"))
		#expect(!joinedHTML.contains("example.com/frame"))
		#expect(joinedHTML.contains("before"))
		#expect(joinedHTML.contains("after"))
	}

	@Test func wrappedYouTubeIframesSurviveBlocks() {
		let wrappers = [
			"<p><iframe src=\"https://www.youtube.com/embed/VIDEOTEST01\"></iframe></p>",
			"<h2><iframe src=\"https://www.youtube.com/embed/VIDEOTEST01\"></iframe></h2>",
			"<blockquote><iframe src=\"https://www.youtube.com/embed/VIDEOTEST01\"></iframe></blockquote>",
			"<figure><iframe src=\"https://www.youtube.com/embed/VIDEOTEST01\"></iframe><figcaption>Video</figcaption></figure>",
			"<ul><li><iframe src=\"https://www.youtube.com/embed/VIDEOTEST01\"></iframe></li></ul>"
		]

		for html in wrappers {
			let blocks = HTMLSourceBlocks.blocks(html)
			#expect(!blocks.isEmpty)
			#expect(blocks.map(\.html).joined().contains("youtube-nocookie.com/embed/VIDEOTEST01"))
		}
	}

	@Test func duplicateYouTubeIframesKeepOneEmbed() {
		let html = """
		<p>Before</p><iframe src="https://www.youtube.com/embed/VIDEOTEST01" width="560"></iframe><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe><p>After</p>
		"""
		let joined = HTMLSourceBlocks.blocks(html).map(\.html).joined()

		#expect(joined.components(separatedBy: "<iframe").count - 1 == 1)
		#expect(joined.components(separatedBy: "</iframe>").count - 1 == 1)
		#expect(!joined.contains("www.youtube.com/embed"))
		#expect(joined.contains("Before"))
		#expect(joined.contains("After"))
	}

	@Test func sanitizedHTMLDropsActiveContentAndKeepsVideo() {
		let html = #"<p onerror="window.__pwned=1">Hello <a href="javascript:alert(1)">link</a><script>window.__pwned=1</script><iframe src="https://www.youtube.com/embed/VIDEOTEST01" width="560"></iframe></p>"#
		let sanitized = HTMLSourceBlocks.sanitizedHTML(html)

		#expect(!sanitized.lowercased().contains("<script"))
		#expect(!sanitized.lowercased().contains("onerror"))
		#expect(!sanitized.lowercased().contains("javascript:"))
		#expect(!sanitized.contains("window.__pwned"))
		#expect(sanitized.contains("Hello"))
		#expect(sanitized.contains("link"))
		#expect(sanitized.contains("<iframe src=\"https://www.youtube-nocookie.com/embed/VIDEOTEST01\""))
		#expect(sanitized.contains("width=\"560\""))
		#expect(sanitized.hasSuffix("</iframe></p>"))
	}

	@Test func sanitizedHTMLPreservesWrapperStructure() {
		let html = #"<div class="x" style="color:red"><p>One</p><p>Two</p></div>"#
		let sanitized = HTMLSourceBlocks.sanitizedHTML(html)

		#expect(sanitized == "<div><p>One</p><p>Two</p></div>")
	}

	@Test func cleaningKeepsSafeSchemesAndRelativeLinks() {
		let html = """
		<p><a href="https://example.com/a">https</a> <a href="http://example.com/b">http</a> <a href="mailto:x@example.com">mail</a> <a href="#section">fragment</a> <a href="/relative/path">relative</a> <a href="//example.com/host">protocol relative</a></p>
		"""
		let joinedHTML = HTMLSourceBlocks.blocks(html).map(\.html).joined()

		#expect(joinedHTML.contains("href=\"https://example.com/a\""))
		#expect(joinedHTML.contains("href=\"http://example.com/b\""))
		#expect(joinedHTML.contains("href=\"mailto:x@example.com\""))
		#expect(joinedHTML.contains("href=\"#section\""))
		#expect(joinedHTML.contains("href=\"/relative/path\""))
		#expect(joinedHTML.contains("href=\"//example.com/host\""))
	}
}
