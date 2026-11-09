//
//  HTMLSourceBlocksFixtureTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

/// Character-level loss check against real feed HTML. Whitespace is normalized
/// before comparing; the loss rate is the share of expected characters that do
/// not appear, in order, in the extracted text.
@Suite final class HTMLSourceBlocksFixtureTests {

	private static let fixtureNames = [
		"wordpress-figure",
		"nested-lists",
		"table",
		"lazy-loading",
		"entities",
		"unclosed"
	]

	@Test(arguments: fixtureNames)
	func fixtureTextHasNoCharacterLoss(_ name: String) throws {
		let html = try fixture(name, extension: "html")
		let expected = try fixture(name, extension: "expected.txt")
		let extracted = HTMLSourceBlocks.plainText(html)

		let normalizedExpected = normalizeWhitespace(expected)
		let normalizedExtracted = normalizeWhitespace(extracted)
		let missing = missingCharacters(expected: normalizedExpected, extracted: normalizedExtracted)

		if !missing.isEmpty {
			Issue.record("Fixture \(name) lost \(missing.count)/\(normalizedExpected.count) characters: \(missing)")
		}
		#expect(missing.isEmpty)
	}

	@Test func maliciousFixtureLeavesNoActiveContent() throws {
		let html = try fixture("malicious", extension: "html")
		let blocks = HTMLSourceBlocks.blocks(html)
		let joinedHTML = blocks.map(\.html).joined().lowercased()
		let joinedText = blocks.map(\.text).joined(separator: "\n").lowercased()
		let forbidden = ["script", "<style", "javascript:", "onclick", "style=", "class=\"x\"", "data:image", "<iframe", "noscript", "<script"]

		for value in forbidden {
			#expect(!joinedHTML.contains(value))
			#expect(!joinedText.contains(value))
		}
	}

	private func fixture(_ name: String, extension fileExtension: String) throws -> String {
		let url = try #require(Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "HTMLSourceBlocks"))
		return try String(contentsOf: url, encoding: .utf8)
	}

	private func normalizeWhitespace(_ text: String) -> String {
		text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Greedy in-order match. Returns the expected characters that could not be
	/// found in the extracted text.
	private func missingCharacters(expected: String, extracted: String) -> String {
		let expectedCharacters = Array(expected)
		let extractedCharacters = Array(extracted)
		var extractedIndex = 0
		var missing = ""
		for character in expectedCharacters {
			var found = false
			while extractedIndex < extractedCharacters.count {
				let candidate = extractedCharacters[extractedIndex]
				extractedIndex += 1
				if candidate == character {
					found = true
					break
				}
			}
			if !found {
				missing.append(character)
			}
		}
		return missing
	}
}
