//
//  RewriteSourceBuilderTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class RewriteSourceBuilderTests {

	@Test func imageTokensFollowDocumentOrder() {
		let html = """
		<p>One <img src="https://example.com/a.png" alt="A"></p>
		<p><img src="https://example.com/b.png" alt="B"></p>
		"""
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.images.map(\.url) == ["https://example.com/a.png", "https://example.com/b.png"])
		#expect(source.promptText.contains("{{img:0}}"))
		#expect(source.promptText.contains("{{img:1}}"))
		#expect(source.promptText.range(of: "{{img:0}}")!.lowerBound < source.promptText.range(of: "{{img:1}}")!.lowerBound)
	}

	@Test func keepsMoreThanEightImages() {
		let html = (0..<10).map { "<p><img src=\"https://example.com/\($0).png\"></p>" }.joined()
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.images.count == 10)
		for index in 0..<10 {
			#expect(source.promptText.contains("{{img:\(index)}}"))
		}
	}

	@Test func resolvesAndFiltersImageURLs() {
		let html = """
		<p><img src="/relative.png"></p>
		<p><img src="//cdn.example.com/protocol.png"></p>
		<p><img src="javascript:alert(1)"></p>
		<p><img src="data:image/png;base64,AAAA"></p>
		"""
		let source = RewriteSourceBuilder.source(html: html, baseURL: URL(string: "https://example.com/post/1"))

		#expect(source.images.map(\.url) == [
			"https://example.com/relative.png",
			"https://cdn.example.com/protocol.png"
		])
	}

	@Test func nestedListsUseIndentedBullets() {
		let html = "<ul><li>Outer<ul><li>Inner</li></ul></li></ul>"
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("- Outer"))
		#expect(source.promptText.contains("  - Inner"))
	}

	@Test func serializesCodeTablesAndLinks() {
		let html = """
		<pre><code class="language-swift">let x = 1</code></pre>
		<table><tr><td>Name</td><td>Value</td></tr></table>
		<p>Visit <a href="https://example.com">Site</a> now</p>
		"""
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("```swift\nlet x = 1\n```"))
		#expect(source.promptText.contains("Name | Value"))
		#expect(source.promptText.contains("[Site](https://example.com)"))
		#expect(source.links == [RewriteLink(label: "Site", url: "https://example.com")])
	}

	@Test func escapesExistingTokenPrefixes() {
		let html = "<p>Keep {{img:0}} and {{t1}} literal</p>"
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains(#"\{\{img:0"#))
		#expect(source.promptText.contains(#"\{\{t1"#))
	}

	@Test func plainTextPathStripsResidualTags() {
		let source = RewriteSourceBuilder.source(text: "<p>Hello</p> world")

		#expect(source.promptText == "Hello world")
		#expect(source.plainText == "Hello world")
	}
}
