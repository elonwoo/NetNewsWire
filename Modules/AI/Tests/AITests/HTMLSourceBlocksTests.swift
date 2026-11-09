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
}
