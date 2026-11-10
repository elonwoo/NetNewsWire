//
//  AIMarkdownRendererTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite final class AIMarkdownRendererTests {

	@Test func rendersBasicTable() {
		let html = AIMarkdownRenderer.html(from: """
		| Name | Value |
		| --- | --- |
		| Alpha | 1 |
		| Beta | 2 |
		""")

		#expect(html.hasPrefix("<div class=\"table-wrap\"><table><thead><tr>"))
		#expect(html.hasSuffix("</tbody></table></div>"))
		#expect(occurrences(of: "<th>", in: html) == 2)
		#expect(occurrences(of: "<td>", in: html) == 4)
		#expect(!html.contains("| Name |"))
		#expect(!html.contains("---"))
	}

	@Test func rendersTableWithoutBoundaryPipes() {
		let html = AIMarkdownRenderer.html(from: """
		A | B
		--- | ---
		1 | 2
		""")

		#expect(html.contains("<th>A</th><th>B</th>"))
		#expect(html.contains("<tr><td>1</td><td>2</td></tr>"))
	}

	@Test func rendersColumnAlignment() {
		let html = AIMarkdownRenderer.html(from: """
		| Left | Center | Right | Plain |
		| :--- | :---: | ---: | --- |
		| a | b | c | d |
		""")

		#expect(html.contains("<th style=\"text-align:left\">Left</th>"))
		#expect(html.contains("<th style=\"text-align:center\">Center</th>"))
		#expect(html.contains("<th style=\"text-align:right\">Right</th>"))
		#expect(html.contains("<th>Plain</th>"))
		#expect(html.contains("<td style=\"text-align:left\">a</td>"))
		#expect(html.contains("<td style=\"text-align:center\">b</td>"))
		#expect(html.contains("<td style=\"text-align:right\">c</td>"))
		#expect(html.contains("<td>d</td>"))
	}

	@Test func rendersInlineFormattingInsideCells() {
		let html = AIMarkdownRenderer.html(from: """
		| Kind | Example |
		| --- | --- |
		| Bold | **strong text** |
		| Link | [example](https://example.com) |
		""")

		#expect(html.contains("<td><strong>strong text</strong></td>"))
		#expect(html.contains("<td><a href=\"https://example.com\">example</a></td>"))
	}

	@Test func keepsPipesInsideCodeAndExpandsEscapedPipes() {
		let html = AIMarkdownRenderer.html(from: """
		| Code | Escaped |
		| --- | --- |
		| `a | b` | x \\| y |
		""")

		#expect(occurrences(of: "<td>", in: html) == 2)
		#expect(html.contains("<td><code>a | b</code></td>"))
		#expect(html.contains("<td>x | y</td>"))
	}

	@Test func keepsPipeLinesWithoutDelimiterAsParagraph() {
		let html = AIMarkdownRenderer.html(from: "| not | a | table |")

		#expect(!html.contains("<table>"))
		#expect(html == "<p>| not | a | table |</p>")
	}

	@Test func resumesParagraphAfterTable() {
		let html = AIMarkdownRenderer.html(from: """
		| Header |
		| --- |
		| value |

		After the table.
		""")

		#expect(html.contains("</tbody></table></div>"))
		#expect(html.hasSuffix("<p>After the table.</p>"))
	}

	@Test func interruptsParagraphAtTableStart() {
		let html = AIMarkdownRenderer.html(from: """
		Intro text.
		| A | B |
		| --- | --- |
		| 1 | 2 |
		""")

		#expect(html.hasPrefix("<p>Intro text.</p>"))
		#expect(html.contains("<table>"))
		#expect(occurrences(of: "<td>", in: html) == 2)
	}

	@Test func padsAndTruncatesRowsToHeaderColumnCount() {
		let html = AIMarkdownRenderer.html(from: """
		| A | B | C |
		| --- | --- | --- |
		| 1 | 2 |
		| 1 | 2 | 3 | 4 |
		""")

		#expect(occurrences(of: "<td>", in: html) == 6)
		#expect(html.contains("<tr><td>1</td><td>2</td><td></td></tr>"))
		#expect(html.contains("<tr><td>1</td><td>2</td><td>3</td></tr>"))
		#expect(!html.contains("<td>4</td>"))
	}

	@Test func doesNotRenderUnsafeLinksInsideCells() {
		let html = AIMarkdownRenderer.html(from: """
		| Name | Link |
		| --- | --- |
		| x | [x](javascript:alert(1)) |
		""")

		#expect(!html.contains("<a href=\"javascript"))
		#expect(html.contains("<td>[x](javascript:alert(1))</td>"))
	}

	@Test func endsTableAtBlockStarts() {
		let html = AIMarkdownRenderer.html(from: """
		| A | B |
		| --- | --- |
		| 1 | 2 |
		# 标题 | 含竖线
		- bullet | item
		1. ordered | item
		> quote | item
		```swift
		let x = 1
		```
		---
		""")

		#expect(html.contains("<td>1</td>"))
		#expect(occurrences(of: "<tr>", in: html) == 2)
		#expect(html.contains("<h1>标题 | 含竖线</h1>"))
		#expect(html.contains("<ul><li>bullet | item</li></ul>"))
		#expect(html.contains("<ol><li>ordered | item</li></ol>"))
		#expect(html.contains("<blockquote><p>quote | item</p></blockquote>"))
		#expect(html.contains("<pre><code class=\"language-swift\">let x = 1</code></pre>"))
		#expect(html.contains("<hr>"))
	}

	@Test func keepsPipeRowsWithoutDelimiterAsParagraph() {
		let html = AIMarkdownRenderer.html(from: """
		| a | b |
		| c | d |
		""")

		#expect(!html.contains("<table>"))
		#expect(html == "<p>| a | b |<br>| c | d |</p>")
	}

	@Test func prefersListsAndQuotesOverTables() {
		let listHTML = AIMarkdownRenderer.html(from: """
		- a | b
		| --- | --- |
		""")
		#expect(!listHTML.contains("<table>"))
		#expect(listHTML.hasPrefix("<ul><li>a | b</li></ul>"))

		let quoteHTML = AIMarkdownRenderer.html(from: """
		> a | b
		| --- | --- |
		""")
		#expect(!quoteHTML.contains("<table>"))
		#expect(quoteHTML.hasPrefix("<blockquote><p>a | b</p></blockquote>"))
	}

	@Test func documentEmbedsYouTubeLink() {
		let html = AIMarkdownRenderer.document(from: "Watch [this video](https://www.youtube.com/watch?v=dQw4w9WgXcQ) now.")

		#expect(html.contains("<iframe"))
		#expect(html.contains("src=\"https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ\""))
		#expect(!html.contains("<a href=\"https://www.youtube.com/watch"))
		#expect(html.contains("<p>Watch "))
		#expect(html.contains(" now.</p>"))
	}

	@Test func documentEmbedsBareYouTubeURL() {
		let html = AIMarkdownRenderer.document(from: "See https://youtu.be/dQw4w9WgXcQ for details.")

		#expect(html.contains("src=\"https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ\""))
		#expect(!html.contains("https://youtu.be/dQw4w9WgXcQ"))
	}

	@Test func documentEmbedsURLWithDoubleEscapedEntities() {
		for suffix in ["&amp;nbsp;", "&amp;amp;", "&amp;#39;", "&amp;amp;amp;nbsp;", "&amp;amp;amp;amp;nbsp;"] {
			let html = AIMarkdownRenderer.document(from: "See https://youtu.be/VIDEOTEST01\(suffix)后续")

			#expect(html.contains("src=\"https://www.youtube-nocookie.com/embed/VIDEOTEST01\""), Comment(rawValue: suffix))
			#expect(html.contains("后续"), Comment(rawValue: suffix))
		}
	}

	@Test func documentKeepsOrdinaryLinksAndText() {
		let html = AIMarkdownRenderer.document(from: "See [example](https://example.com) and **bold**.")

		#expect(html.contains("<a href=\"https://example.com\">example</a>"))
		#expect(html.contains("<strong>bold</strong>"))
		#expect(!html.contains("<iframe"))

		let plain = AIMarkdownRenderer.document(from: "Just text.")
		#expect(plain.contains("<p>Just text.</p>"))
		#expect(!plain.contains("youtube-nocookie.com"))
	}
}

private func occurrences(of needle: String, in haystack: String) -> Int {
	haystack.components(separatedBy: needle).count - 1
}
