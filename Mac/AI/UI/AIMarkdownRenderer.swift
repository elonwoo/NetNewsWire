//
//  AIMarkdownRenderer.swift
//  NetNewsWire
//

import Foundation

/// Minimal Markdown to HTML renderer for AI rewrite output.
///
/// The rewrite model returns Markdown and the app has no Markdown library, so
/// this covers the constructs an article rewrite actually uses: headings,
/// paragraphs, lists, quotes, code blocks, emphasis and links. HTML is escaped
/// before any inline formatting, and only safe link schemes are kept.
enum AIMarkdownRenderer {

	/// Wraps rendered Markdown in the reading pane's HTML document.
	static func document(from markdown: String) -> String {
		let body = html(from: markdown)
		let content = body.isEmpty ? "<p class=\"empty\">改写内容为空。</p>" : body

		return """
		<!doctype html>
		<html>
		<head>
		<meta charset="utf-8">
		<style>
		:root {
			color-scheme: light dark;
			--bg: #ffffff;
			--fg: #1d1d1f;
			--muted: #6e6e73;
			--line: #e5e5e7;
			--accent: #0a84ff;
		}
		@media (prefers-color-scheme: dark) {
			:root {
				--bg: #1e1e1e;
				--fg: #e8e8e8;
				--muted: #a1a1a6;
				--line: #3a3a3c;
				--accent: #4da3ff;
			}
		}
		* { box-sizing: border-box; }
		html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
		body { font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; font-size: 15px; line-height: 1.75; padding: 20px 24px 48px; }
		h1, h2, h3, h4, h5, h6 { line-height: 1.4; margin: 24px 0 10px; }
		h1 { font-size: 21px; }
		h2 { font-size: 18px; }
		h3 { font-size: 16px; }
		p { margin: 0 0 14px; }
		ul, ol { margin: 0 0 14px; padding-left: 24px; }
		li { margin: 4px 0; }
		a { color: var(--accent); }
		img { max-width: 100%; height: auto; }
		blockquote { margin: 12px 0; padding-left: 14px; border-left: 3px solid var(--line); color: var(--muted); }
		hr { border: none; border-top: 1px solid var(--line); margin: 20px 0; }
		pre, code { font-family: "SF Mono", Menlo, monospace; font-size: 13px; }
		pre { overflow-x: auto; padding: 10px; background: rgba(127, 127, 127, 0.12); border-radius: 6px; }
		.empty { color: var(--muted); }
		</style>
		</head>
		<body>
		\(content)
		</body>
		</html>
		"""
	}

	static func html(from markdown: String) -> String {
		let normalized = markdown
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
		let lines = normalized.components(separatedBy: "\n")

		var blocks: [String] = []
		var index = 0

		while index < lines.count {
			let line = lines[index].trimmingCharacters(in: .whitespaces)

			if line.isEmpty {
				index += 1
				continue
			}

			if line.hasPrefix("```") {
				let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
				var codeLines: [String] = []
				index += 1
				while index < lines.count {
					let candidate = lines[index].trimmingCharacters(in: .whitespaces)
					if candidate.hasPrefix("```") {
						index += 1
						break
					}
					codeLines.append(lines[index])
					index += 1
				}
				let attribute = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
				blocks.append("<pre><code\(attribute)>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
				continue
			}

			if let heading = heading(in: line) {
				blocks.append("<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>")
				index += 1
				continue
			}

			if isHorizontalRule(line) {
				blocks.append("<hr>")
				index += 1
				continue
			}

			if line.hasPrefix(">") {
				var quoteLines: [String] = []
				while index < lines.count {
					let candidate = lines[index].trimmingCharacters(in: .whitespaces)
					guard candidate.hasPrefix(">") else {
						break
					}
					var text = String(candidate.dropFirst())
					if text.hasPrefix(" ") {
						text.removeFirst()
					}
					quoteLines.append(text)
					index += 1
				}
				blocks.append("<blockquote>\(paragraphs(from: quoteLines))</blockquote>")
				continue
			}

			if isOrderedListMarker(line) || isUnorderedListMarker(line) {
				let ordered = isOrderedListMarker(line)
				var items: [String] = []
				while index < lines.count {
					let candidate = lines[index].trimmingCharacters(in: .whitespaces)
					let isItem = ordered ? isOrderedListMarker(candidate) : isUnorderedListMarker(candidate)
					guard isItem else {
						break
					}
					items.append("<li>\(inline(stripListMarker(from: candidate, ordered: ordered)))</li>")
					index += 1
				}
				let tag = ordered ? "ol" : "ul"
				blocks.append("<\(tag)>\(items.joined())</\(tag)>")
				continue
			}

			var paragraphLines: [String] = []
			while index < lines.count {
				let candidate = lines[index].trimmingCharacters(in: .whitespaces)
				if candidate.isEmpty || startsBlock(candidate) {
					break
				}
				paragraphLines.append(candidate)
				index += 1
			}
			if paragraphLines.isEmpty {
				index += 1
				continue
			}
			blocks.append("<p>\(inline(paragraphLines.joined(separator: "\n")))</p>")
		}

		return blocks.joined(separator: "\n")
	}
}

// MARK: - Block helpers

private extension AIMarkdownRenderer {

	static func heading(in line: String) -> (level: Int, text: String)? {
		guard let groups = firstMatch(pattern: "^(#{1,6})\\s+(.+)$", in: line), groups.count >= 3 else {
			return nil
		}
		return (groups[1].count, groups[2].trimmingCharacters(in: .whitespaces))
	}

	static func isHorizontalRule(_ line: String) -> Bool {
		let compact = line.replacingOccurrences(of: " ", with: "")
		guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else {
			return false
		}
		return compact.allSatisfy { $0 == first }
	}

	static func isUnorderedListMarker(_ line: String) -> Bool {
		firstMatch(pattern: "^[-*+]\\s+", in: line) != nil
	}

	static func isOrderedListMarker(_ line: String) -> Bool {
		firstMatch(pattern: "^\\d+[.)]\\s+", in: line) != nil
	}

	static func stripListMarker(from line: String, ordered: Bool) -> String {
		let pattern = ordered ? "^\\d+[.)]\\s+" : "^[-*+]\\s+"
		return replacingMatches(pattern: pattern, in: line, with: "")
	}

	static func startsBlock(_ line: String) -> Bool {
		line.hasPrefix("```")
			|| heading(in: line) != nil
			|| isHorizontalRule(line)
			|| line.hasPrefix(">")
			|| isUnorderedListMarker(line)
			|| isOrderedListMarker(line)
	}

	static func paragraphs(from lines: [String]) -> String {
		var paragraphs: [[String]] = []
		var current: [String] = []
		for line in lines {
			if line.trimmingCharacters(in: .whitespaces).isEmpty {
				if !current.isEmpty {
					paragraphs.append(current)
					current = []
				}
			} else {
				current.append(line)
			}
		}
		if !current.isEmpty {
			paragraphs.append(current)
		}
		return paragraphs
			.map { "<p>\(inline($0.joined(separator: "\n")))</p>" }
			.joined()
	}
}

// MARK: - Inline helpers

private extension AIMarkdownRenderer {

	static func inline(_ text: String) -> String {
		var result = escape(text)
		var placeholders: [String] = []

		func stash(_ html: String) -> String {
			placeholders.append(html)
			return "\u{E000}\(placeholders.count - 1)\u{E001}"
		}

		result = replace(pattern: "`([^`\n]+)`", in: result) { groups in
			stash("<code>\(groups[1])</code>")
		}

		result = replace(pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", in: result) { groups in
			guard let url = safeURL(groups[2]) else {
				return groups[0]
			}
			return stash("<img src=\"\(url)\" alt=\"\(groups[1])\">")
		}

		result = replace(pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", in: result) { groups in
			guard let url = safeURL(groups[2]) else {
				return groups[0]
			}
			return stash("<a href=\"\(url)\">\(groups[1])</a>")
		}

		result = replace(pattern: "\\*\\*([^*\n]+)\\*\\*", in: result) { groups in
			"<strong>\(groups[1])</strong>"
		}

		result = replace(pattern: "__([^_\n]+)__", in: result) { groups in
			"<strong>\(groups[1])</strong>"
		}

		result = replace(pattern: "~~([^~\n]+)~~", in: result) { groups in
			"<del>\(groups[1])</del>"
		}

		result = replace(pattern: "\\*([^*\n]+)\\*", in: result) { groups in
			"<em>\(groups[1])</em>"
		}

		result = replace(pattern: "(?<![A-Za-z0-9_])_([^_\n]+)_(?![A-Za-z0-9_])", in: result) { groups in
			"<em>\(groups[1])</em>"
		}

		for (index, html) in placeholders.enumerated() {
			result = result.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: html)
		}

		return result.replacingOccurrences(of: "\n", with: "<br>")
	}

	static func safeURL(_ url: String) -> String? {
		let lowered = url.lowercased()
		if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:") || lowered.hasPrefix("#") || lowered.hasPrefix("/") {
			return url
		}
		return nil
	}

	static func escape(_ string: String) -> String {
		string
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}
}

// MARK: - Regex helpers

private extension AIMarkdownRenderer {

	static func firstMatch(pattern: String, in text: String) -> [String]? {
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return nil
		}
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		guard let match = regex.firstMatch(in: text, options: [], range: range) else {
			return nil
		}
		return groups(from: match, in: text)
	}

	static func replace(pattern: String, in text: String, transform: ([String]) -> String) -> String {
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return text
		}
		let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
		guard !matches.isEmpty else {
			return text
		}

		var result = ""
		var location = text.startIndex
		for match in matches {
			guard let range = Range(match.range, in: text) else {
				continue
			}
			result += text[location..<range.lowerBound]
			result += transform(groups(from: match, in: text))
			location = range.upperBound
		}
		result += text[location..<text.endIndex]
		return result
	}

	static func replacingMatches(pattern: String, in text: String, with replacement: String) -> String {
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return text
		}
		return regex.stringByReplacingMatches(
			in: text,
			options: [],
			range: NSRange(text.startIndex..<text.endIndex, in: text),
			withTemplate: replacement
		)
	}

	static func groups(from match: NSTextCheckingResult, in text: String) -> [String] {
		var groups: [String] = []
		for index in 0..<match.numberOfRanges {
			guard let range = Range(match.range(at: index), in: text) else {
				groups.append("")
				continue
			}
			groups.append(String(text[range]))
		}
		return groups
	}
}
