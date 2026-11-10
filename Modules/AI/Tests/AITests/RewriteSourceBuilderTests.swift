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

	@Test func serializesYouTubeIframeAsWatchURL() {
		let html = """
		<p>Intro</p><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe>
		"""
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("Intro"))
		#expect(source.promptText.components(separatedBy: "\n").contains("https://www.youtube.com/watch?v=VIDEOTEST01"))
	}

	@Test func omitsNonYouTubeIframeFromRewriteSource() {
		let html = """
		<p>Intro</p><iframe src="https://player.vimeo.com/video/123"></iframe>
		"""
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("Intro"))
		#expect(!source.promptText.contains("vimeo"))
		#expect(!source.promptText.contains("youtube"))
	}

	@Test func serializesImageAndYouTubeIframeTogether() {
		let html = """
		<p>Intro</p><img src="https://example.com/a.png" alt="A"><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe>
		"""
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.images.map(\.url) == ["https://example.com/a.png"])
		#expect(source.promptText.contains("{{img:0}}"))
		#expect(source.promptText.contains("https://www.youtube.com/watch?v=VIDEOTEST01"))
	}

	@Test func serializesIframeInsideParagraphAtItsPosition() {
		let html = #"<p>Intro <iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe> Outro</p>"#
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("Intro"))
		#expect(source.promptText.contains("Outro"))
		#expect(source.promptText.components(separatedBy: "\n").contains("https://www.youtube.com/watch?v=VIDEOTEST01"))
	}

	@Test func serializesIframeInsideFigure() {
		let html = #"<figure><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe><figcaption>Video</figcaption></figure>"#
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("Video"))
		#expect(source.promptText.components(separatedBy: "\n").contains("https://www.youtube.com/watch?v=VIDEOTEST01"))
	}

	@Test func serializesIframeInsideListItemOnItsOwnLine() {
		let html = #"<ul><li>Item <iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe></li></ul>"#
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("- Item"))
		#expect(source.promptText.components(separatedBy: "\n").contains("https://www.youtube.com/watch?v=VIDEOTEST01"))
		#expect(!source.promptText.contains("VIDEOTEST01Item"))
	}

	@Test func keepsBothLinksToTheSameVideo() {
		let html = #"<p><a href="https://youtu.be/VIDEOTEST01">one</a> <a href="https://youtu.be/VIDEOTEST01">two</a></p>"#
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)

		#expect(source.promptText.contains("[one](https://youtu.be/VIDEOTEST01)"))
		#expect(source.promptText.contains("[two](https://youtu.be/VIDEOTEST01)"))
		#expect(source.links.count == 2)
	}

	@Test func deduplicatesWatchURLsPerSource() {
		let html = """
		<p>One <iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe></p><p>Two <iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe></p>
		"""
		let source = RewriteSourceBuilder.source(html: html, baseURL: nil)
		let count = source.promptText.components(separatedBy: "https://www.youtube.com/watch?v=VIDEOTEST01").count - 1

		#expect(count == 1)
	}
}
