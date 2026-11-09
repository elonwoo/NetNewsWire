//
//  AIRewriteQualityValidatorTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIRewriteQualityValidatorTests {

	@Test func validChineseRewritePasses() {
		let source = String(repeating: "Source text with data. ", count: 40)
		let body = String(repeating: "这是改写后的中文内容，用来验证质量校验可以通过。", count: 4)
			+ "\n\n"
			+ String(repeating: "第二段同样需要足够的中文长度和段落。", count: 4)

		let result = AIRewriteQualityValidator.evaluate(sourceText: source, body: body)

		#expect(result.ok)
		#expect(result.hanLength >= result.minHanLength)
		#expect(result.paragraphCount >= result.minParagraphCount)
	}

	@Test func refusalIsRejected() {
		let source = String(repeating: "Source text. ", count: 100)
		let result = AIRewriteQualityValidator.evaluate(sourceText: source, body: "抱歉，我无法完成这个改写。")

		#expect(!result.ok)
		#expect(result.reason == "模型返回了拒答")
	}

	@Test func aiRefusalIsRejected() {
		let source = String(repeating: "Source text. ", count: 100)
		let result = AIRewriteQualityValidator.evaluate(sourceText: source, body: "作为 AI 助手，我不能处理这类内容。")

		#expect(!result.ok)
		#expect(result.reason == "模型返回了拒答")
	}

	@Test func shortChineseBodyIsRejected() {
		let source = String(repeating: "Source text. ", count: 100)
		let result = AIRewriteQualityValidator.evaluate(sourceText: source, body: "你好。\n\n世界。")

		#expect(!result.ok)
		#expect(result.reason.hasPrefix("中文正文过短"))
	}

	@Test func missingParagraphsAreRejected() {
		let source = String(repeating: "Source text. ", count: 100)
		let body = String(repeating: "这一段中文很长但整篇只有一个段落。", count: 20)
		let result = AIRewriteQualityValidator.evaluate(sourceText: source, body: body)

		#expect(result.sourceLength >= 700)
		#expect(!result.ok)
		#expect(result.reason.hasPrefix("正文段落不足"))
	}

	@Test func markdownAndHTMLDoNotCountAsSignal() {
		let plain = AIRewriteQualityValidator.plainText("## 标题\n\n**加粗** [链接](https://example.com)\n\n正文")
		#expect(!plain.contains("#"))
		#expect(!plain.contains("**"))
		#expect(!plain.contains("https://example.com"))
		#expect(plain.contains("正文"))
	}

	@Test func longSourceRequiresThreeParagraphs() {
		let source = String(repeating: "Source text. ", count: 300)
		let twoParagraphs = String(repeating: "这一段中文内容足够长，用来撑过中文字数门槛。", count: 20)
			+ "\n\n"
			+ String(repeating: "第二段中文内容同样足够长。", count: 20)
		let result = AIRewriteQualityValidator.evaluate(sourceText: source, body: twoParagraphs)

		#expect(result.minParagraphCount == 3)
		#expect(!result.ok)
		#expect(result.reason.hasPrefix("正文段落不足"))
	}

	@Test func normalizedOutputCountsOnlyCanonicalPlainText() {
		let output = "# 标题\n\n<p>正文内容</p> {{img:0}}"
		let normalized = RewriteOutputNormalizer.normalize(output, images: [HTMLImageRef(url: "https://example.com/a.png", alt: "A")])
		let plain = AIRewriteQualityValidator.plainText(normalized)

		#expect(!plain.contains("<"))
		#expect(!plain.contains("{{img:"))
		#expect(plain.contains("正文内容"))
	}
}
