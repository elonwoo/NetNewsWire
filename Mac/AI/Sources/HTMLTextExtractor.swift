//
//  HTMLTextExtractor.swift
//  NetNewsWire
//

import Foundation

/// Turns a downloaded HTML page into readable text.
///
/// The source fetchers only need enough structure to judge whether a page has
/// usable content, so this keeps paragraph breaks and drops everything else.
enum HTMLTextExtractor {

	static func text(fromHTML html: String) -> String {
		var result = html
		for element in ["head", "script", "style", "noscript", "template", "svg", "iframe", "canvas", "video", "audio", "object"] {
			result = removingElement(element, from: result)
		}
		result = removingComments(from: result)
		result = result.replacingOccurrences(of: "(?i)<br\\b[^>]*>", with: "\n", options: .regularExpression)
		result = result.replacingOccurrences(of: "(?i)</?(p|div|section|article|header|footer|li|ul|ol|tr|table|h[1-6]|blockquote|pre|figure|figcaption)\\b[^>]*>", with: "\n", options: .regularExpression)
		result = result.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
		result = decodeEntities(result)
		return normalizeWhitespace(result).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func title(fromHTML html: String) -> String? {
		let patterns = [
			"(?is)<meta\\s+[^>]*property\\s*=\\s*[\"']og:title[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"']",
			"(?is)<meta\\s+[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*property\\s*=\\s*[\"']og:title[\"']",
			"(?is)<title\\b[^>]*>(.*?)</title\\s*>",
			"(?is)<h1\\b[^>]*>(.*?)</h1\\s*>"
		]
		for pattern in patterns {
			guard let value = firstCapture(pattern: pattern, in: html) else {
				continue
			}
			let cleaned = text(fromHTML: value)
			if !cleaned.isEmpty {
				return cleaned
			}
		}
		return nil
	}

	/// Reads one attribute out of the attribute portion of an HTML tag.
	static func attributeValue(named name: String, in attributes: String) -> String? {
		let pattern = "(?i)\(name)\\s*=\\s*([\"'])(.*?)\\1"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return nil
		}
		let range = NSRange(attributes.startIndex..., in: attributes)
		guard let match = regex.firstMatch(in: attributes, range: range),
			  let valueRange = Range(match.range(at: 2), in: attributes) else {
			return nil
		}
		return String(attributes[valueRange])
	}

	static func decodeEntities(_ string: String) -> String {
		guard string.contains("&") else {
			return string
		}

		var output = ""
		output.reserveCapacity(string.count)
		var index = string.startIndex

		while index < string.endIndex {
			guard string[index] == "&" else {
				output.append(string[index])
				index = string.index(after: index)
				continue
			}

			guard let semicolon = string[index...].firstIndex(of: ";"),
				  string.distance(from: index, to: semicolon) <= 12 else {
				output.append(string[index])
				index = string.index(after: index)
				continue
			}

			let entity = String(string[string.index(after: index)..<semicolon])
			if let decoded = decodeEntity(entity) {
				output.append(decoded)
				index = string.index(after: semicolon)
			} else {
				output.append(string[index])
				index = string.index(after: index)
			}
		}
		return output
	}
}

private extension HTMLTextExtractor {

	static let namedEntities: [String: String] = [
		"amp": "&",
		"lt": "<",
		"gt": ">",
		"quot": "\"",
		"apos": "'",
		"nbsp": " ",
		"ndash": "–",
		"mdash": "—",
		"hellip": "…",
		"rsquo": "’",
		"lsquo": "‘",
		"ldquo": "“",
		"rdquo": "”",
		"middot": "·",
		"copy": "©",
		"reg": "®",
		"trade": "™"
	]

	static func removingElement(_ name: String, from html: String) -> String {
		let pattern = "(?is)<\(name)\\b[^>]*>.*?</\(name)\\s*>"
		return html.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
	}

	static func removingComments(from html: String) -> String {
		html.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
	}

	static func decodeEntity(_ entity: String) -> String? {
		if entity.hasPrefix("#") {
			let scalarText = String(entity.dropFirst())
			let value: UInt32?
			if scalarText.hasPrefix("x") || scalarText.hasPrefix("X") {
				value = UInt32(scalarText.dropFirst(), radix: 16)
			} else {
				value = UInt32(scalarText, radix: 10)
			}
			guard let value, let scalar = UnicodeScalar(value) else {
				return nil
			}
			return String(scalar)
		}
		return namedEntities[entity.lowercased()]
	}

	static func normalizeWhitespace(_ string: String) -> String {
		var lines: [String] = []
		for line in string.components(separatedBy: .newlines) {
			let collapsed = line.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
			let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
			if !trimmed.isEmpty {
				lines.append(trimmed)
			}
		}
		return lines.joined(separator: "\n")
	}

	static func firstCapture(pattern: String, in string: String) -> String? {
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return nil
		}
		let range = NSRange(string.startIndex..., in: string)
		guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1 else {
			return nil
		}
		guard let captureRange = Range(match.range(at: 1), in: string) else {
			return nil
		}
		return String(string[captureRange])
	}
}
