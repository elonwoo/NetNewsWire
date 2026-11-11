//
//  AIChatMarkdownRenderer.swift
//  NetNewsWire
//

import AppKit

/// Renders assistant chat replies as attributed text.
///
/// Blocks are parsed here and each one gets its own paragraph style; inline
/// spans are parsed by Foundation so links, emphasis and inline code keep the
/// attributes the system produces.
enum AIChatMarkdownRenderer {

	private static var bodyFont: NSFont {
		NSFont.systemFont(ofSize: 13)
	}

	private static let codeFontSize: CGFloat = 12

	static func attributedString(from markdown: String) -> NSAttributedString {
		let normalized = markdown
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
		let lines = normalized.components(separatedBy: "\n")

		let result = NSMutableAttributedString()
		var index = 0
		var isFirstBlock = true

		func append(_ block: NSAttributedString) {
			guard block.length > 0 else {
				return
			}
			if !isFirstBlock {
				result.append(NSAttributedString(string: "\n"))
			}
			isFirstBlock = false
			result.append(block)
		}

		while index < lines.count {
			let rawLine = lines[index]
			let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

			if trimmed.isEmpty {
				index += 1
				continue
			}

			if trimmed.hasPrefix("```") {
				append(codeBlock(lines: lines, index: &index))
				continue
			}

			if let heading = heading(in: trimmed) {
				append(inlineBlock(
					text: heading.text,
					font: headingFont(for: heading.level),
					paragraphStyle: headingParagraphStyle()
				))
				index += 1
				continue
			}

			if isHorizontalRule(trimmed) {
				append(ruleBlock())
				index += 1
				continue
			}

			if trimmed.hasPrefix(">") {
				append(quoteBlock(lines: lines, index: &index))
				continue
			}

			if listMarker(in: rawLine) != nil {
				append(listBlock(lines: lines, index: &index))
				continue
			}

			if trimmed.hasPrefix("|") {
				append(tableBlock(lines: lines, index: &index))
				continue
			}

			append(paragraphBlock(lines: lines, index: &index))
		}

		return result
	}
}

// MARK: - Block parsing

private extension AIChatMarkdownRenderer {

	struct Heading {
		let level: Int
		let text: String
	}

	struct ListMarker {
		let ordered: Bool
		let level: Int
		let content: String
	}

	static func heading(in line: String) -> Heading? {
		let hashes = line.prefix { $0 == "#" }.count
		guard (1...6).contains(hashes) else {
			return nil
		}
		let rest = line.dropFirst(hashes)
		guard let first = rest.first, first == " " || first == "\t" else {
			return nil
		}
		let text = rest.trimmingCharacters(in: .whitespaces)
		guard !text.isEmpty else {
			return nil
		}
		return Heading(level: hashes, text: text)
	}

	static func headingFont(for level: Int) -> NSFont {
		let size: CGFloat
		switch level {
		case 1:
			size = 16
		case 2:
			size = 15
		case 3:
			size = 14
		default:
			size = 13.5
		}
		return NSFont.systemFont(ofSize: size, weight: .semibold)
	}

	static func isHorizontalRule(_ line: String) -> Bool {
		let compact = line.replacingOccurrences(of: " ", with: "")
		guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else {
			return false
		}
		return compact.allSatisfy { $0 == first }
	}

	static func listMarker(in rawLine: String) -> ListMarker? {
		let leadingSpaces = rawLine.prefix { $0 == " " }.count
		let level = leadingSpaces / 2
		var rest = rawLine.dropFirst(leadingSpaces)

		if let first = rest.first, first == "-" || first == "*" || first == "+" {
			let afterMarker = rest.dropFirst()
			guard let space = afterMarker.first, space == " " || space == "\t" else {
				return nil
			}
			return ListMarker(ordered: false, level: level, content: afterMarker.trimmingCharacters(in: .whitespaces))
		}

		let digits = rest.prefix { $0.isNumber }.count
		guard digits > 0 else {
			return nil
		}
		rest = rest.dropFirst(digits)
		guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else {
			return nil
		}
		let afterMarker = rest.dropFirst()
		guard let space = afterMarker.first, space == " " || space == "\t" else {
			return nil
		}
		return ListMarker(ordered: true, level: level, content: afterMarker.trimmingCharacters(in: .whitespaces))
	}

	static func paragraphBlock(lines: [String], index: inout Int) -> NSAttributedString {
		let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
		index += 1
		return inlineBlock(text: trimmed, font: bodyFont, paragraphStyle: bodyParagraphStyle())
	}

	static func codeBlock(lines: [String], index: inout Int) -> NSAttributedString {
		index += 1
		var codeLines: [String] = []
		while index < lines.count {
			let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") {
				index += 1
				break
			}
			codeLines.append(lines[index])
			index += 1
		}

		let text = codeLines.joined(separator: "\n")
		let attributed = NSMutableAttributedString(string: text)
		let full = NSRange(location: 0, length: attributed.length)
		guard full.length > 0 else {
			return attributed
		}
		let paragraph = NSMutableParagraphStyle()
		paragraph.headIndent = 6
		paragraph.firstLineHeadIndent = 6
		paragraph.paragraphSpacingBefore = 8
		paragraph.paragraphSpacing = 8
		paragraph.lineSpacing = 2
		attributed.addAttributes([
			.font: NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
			.foregroundColor: NSColor.labelColor,
			.backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15),
			.paragraphStyle: paragraph
		], range: full)
		return attributed
	}

	static func quoteBlock(lines: [String], index: inout Int) -> NSAttributedString {
		var quoteLines: [String] = []
		while index < lines.count {
			let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
			guard trimmed.hasPrefix(">") else {
				break
			}
			var text = String(trimmed.dropFirst())
			if text.hasPrefix(" ") {
				text.removeFirst()
			}
			quoteLines.append(text)
			index += 1
		}

		let paragraph = NSMutableParagraphStyle()
		paragraph.headIndent = 10
		paragraph.firstLineHeadIndent = 10
		paragraph.paragraphSpacing = 7
		paragraph.lineSpacing = 3
		return inlineBlock(text: quoteLines.joined(separator: "\n"), font: bodyFont, color: .secondaryLabelColor, paragraphStyle: paragraph)
	}

	static func tableBlock(lines: [String], index: inout Int) -> NSAttributedString {
		var rows: [String] = []
		while index < lines.count {
			let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
			guard trimmed.hasPrefix("|") else {
				break
			}
			rows.append(trimmed)
			index += 1
		}

		let attributed = NSMutableAttributedString(string: rows.joined(separator: "\n"))
		let full = NSRange(location: 0, length: attributed.length)
		guard full.length > 0 else {
			return attributed
		}
		attributed.addAttributes([
			.font: NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
			.foregroundColor: NSColor.labelColor,
			.paragraphStyle: bodyParagraphStyle()
		], range: full)
		return attributed
	}

	static func listBlock(lines: [String], index: inout Int) -> NSAttributedString {
		var items: [ListMarker] = []
		while index < lines.count, let marker = listMarker(in: lines[index]) {
			items.append(marker)
			index += 1
		}

		var orderedCounters: [Int: Int] = [:]
		let result = NSMutableAttributedString()

		for (itemIndex, item) in items.enumerated() {
			if itemIndex > 0 {
				result.append(NSAttributedString(string: "\n"))
			}

			let paragraph = NSMutableParagraphStyle()
			let headIndent = 18 + CGFloat(item.level) * 12
			paragraph.firstLineHeadIndent = 0
			paragraph.headIndent = headIndent
			paragraph.tabStops = [NSTextTab(textAlignment: .left, location: headIndent)]
			paragraph.paragraphSpacing = itemIndex == items.count - 1 ? 7 : 3
			paragraph.lineSpacing = 3

			let marker: String
			if item.ordered {
				let next = (orderedCounters[item.level] ?? 0) + 1
				orderedCounters[item.level] = next
				marker = "\(next).\t"
			} else {
				marker = "•\t"
			}

			let itemText = NSMutableAttributedString(string: marker)
			itemText.addAttributes([
				.font: bodyFont,
				.foregroundColor: NSColor.labelColor
			], range: NSRange(location: 0, length: itemText.length))
			itemText.append(inlineAttributed(item.content, baseFont: bodyFont, color: .labelColor))
			itemText.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: itemText.length))
			result.append(itemText)
		}

		return result
	}

	static func ruleBlock() -> NSAttributedString {
		let attributed = NSMutableAttributedString(string: "———")
		let paragraph = NSMutableParagraphStyle()
		paragraph.paragraphSpacingBefore = 6
		paragraph.paragraphSpacing = 6
		attributed.addAttributes([
			.font: bodyFont,
			.foregroundColor: NSColor.tertiaryLabelColor,
			.paragraphStyle: paragraph
		], range: NSRange(location: 0, length: attributed.length))
		return attributed
	}
}

// MARK: - Inline parsing

private extension AIChatMarkdownRenderer {

	static func bodyParagraphStyle() -> NSParagraphStyle {
		let paragraph = NSMutableParagraphStyle()
		paragraph.paragraphSpacing = 7
		paragraph.lineSpacing = 3
		return paragraph
	}

	static func headingParagraphStyle() -> NSParagraphStyle {
		let paragraph = NSMutableParagraphStyle()
		paragraph.paragraphSpacingBefore = 10
		paragraph.paragraphSpacing = 4
		return paragraph
	}

	static func inlineBlock(text: String, font: NSFont, color: NSColor = .labelColor, paragraphStyle: NSParagraphStyle? = nil) -> NSAttributedString {
		let attributed = NSMutableAttributedString(attributedString: inlineAttributed(text, baseFont: font, color: color))
		if let paragraphStyle, attributed.length > 0 {
			attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributed.length))
		}
		return attributed
	}

	static func inlineAttributed(_ text: String, baseFont: NSFont, color: NSColor) -> NSAttributedString {
		let parsed: NSMutableAttributedString
		do {
			let attributed = try AttributedString(
				markdown: text,
				options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
			)
			parsed = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
		} catch {
			parsed = NSMutableAttributedString(string: text)
		}

		let full = NSRange(location: 0, length: parsed.length)
		guard full.length > 0 else {
			return parsed
		}

		parsed.addAttribute(.font, value: baseFont, range: full)
		parsed.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
			if value == nil {
				parsed.addAttribute(.foregroundColor, value: color, range: range)
			}
		}
		parsed.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
			guard let number = value as? NSNumber else {
				return
			}
			let intent = UInt(number.intValue)
			if intent & 2 != 0 {
				let font = parsed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? baseFont
				parsed.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
			}
			if intent & 1 != 0 {
				let font = parsed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? baseFont
				parsed.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: range)
			}
			if intent & 4 != 0 {
				parsed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 0.5, weight: .regular), range: range)
				parsed.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.15), range: range)
			}
		}
		return parsed
	}
}
