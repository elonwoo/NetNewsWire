//
//  AIChatMarkdownTests.swift
//  NetNewsWireTests
//

import AppKit
import Testing
@testable import NetNewsWire

@Suite final class AIChatMarkdownTests {

	@Test func rendersBoldRun() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "这是**粗体**文字")
		let range = try #require(self.range(of: "粗体", in: attributed))
		let font = try #require(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
		#expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
	}

	@Test func rendersItalicRun() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "这是*斜体*文字")
		let range = try #require(self.range(of: "斜体", in: attributed))
		let font = try #require(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
		#expect(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
	}

	@Test func rendersInlineCodeMonospaced() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "这是 `code` 文字")
		let range = try #require(self.range(of: "code", in: attributed))
		let font = try #require(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
		#expect(font.isFixedPitch)
		#expect(abs(font.pointSize - 12.5) < 0.01)
	}

	@Test func rendersListsWithLiteralBullets() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "- 项目一\n- 项目二")
		#expect(attributed.string.contains("•"))
		let range = try #require(self.range(of: "项目一", in: attributed))
		let paragraph = try #require(attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
		#expect(paragraph.textLists.isEmpty)
		#expect(paragraph.headIndent >= 18)
		#expect(paragraph.firstLineHeadIndent == 0)
	}

	@Test func rendersOrderedListsWithNumberedMarkers() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "1. 第一步\n2. 第二步\n3. 第三步")
		#expect(attributed.string.contains("1.\t"))
		#expect(attributed.string.contains("2.\t"))
		#expect(attributed.string.contains("3.\t"))
		let range = try #require(self.range(of: "第一步", in: attributed))
		let paragraph = try #require(attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
		#expect(paragraph.textLists.isEmpty)
		#expect(paragraph.headIndent >= 18)
	}

	@Test func rendersCodeBlockMonospacedWithBackground() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "```\nlet x = 1\n```")
		let range = try #require(self.range(of: "let x = 1", in: attributed))
		let font = try #require(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
		#expect(font.isFixedPitch)
		#expect(abs(font.pointSize - 12) < 0.01)
		#expect(attributed.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil)
	}

	@Test func rendersHeadingSizes() throws {
		let expectations: [(String, String, CGFloat)] = [
			("# 一级", "一级", 16),
			("## 二级", "二级", 15),
			("### 三级", "三级", 14),
			("#### 四级", "四级", 13.5)
		]
		for (markdown, text, size) in expectations {
			let attributed = AIChatMarkdownRenderer.attributedString(from: markdown)
			let range = try #require(self.range(of: text, in: attributed))
			let font = try #require(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
			#expect(abs(font.pointSize - size) < 0.01)
		}
	}

	@Test func rendersConsecutiveLinesAsSeparateParagraphs() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "第一点\n第二点")
		let range = try #require(self.range(of: "第二点", in: attributed))
		var effectiveRange = NSRange()
		let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: &effectiveRange) as? NSParagraphStyle
		let paragraph = try #require(style)
		#expect(effectiveRange.location == range.location)
		#expect(paragraph.paragraphSpacing == 7)
		#expect(paragraph.lineSpacing == 3)
	}

	@Test func rendersQuoteIndented() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "> 引用文字")
		let range = try #require(self.range(of: "引用文字", in: attributed))
		let paragraph = try #require(attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
		#expect(paragraph.headIndent == 10)
	}

	@Test func keepsUnclosedBoldLiteral() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "这是 **未闭合")
		#expect(attributed.string == "这是 **未闭合")
	}

	@Test func keepsLinkAttribute() throws {
		let attributed = AIChatMarkdownRenderer.attributedString(from: "[链接](https://example.com)")
		let range = try #require(self.range(of: "链接", in: attributed))
		let value = attributed.attribute(.link, at: range.location, effectiveRange: nil)
		let url = try #require(value as? URL)
		#expect(url.absoluteString == "https://example.com")
	}

	private func range(of needle: String, in attributed: NSAttributedString) -> NSRange? {
		let range = (attributed.string as NSString).range(of: needle)
		return range.location == NSNotFound ? nil : range
	}
}
