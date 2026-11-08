//
//  AIBodySegmenterTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIBodySegmenterTests {

	@Test func smallSourceStaysInOneSegment() {
		let source = "<p>Hello</p>\n<p>World</p>"
		let segments = AIBodySegmenter.segments(source: source, isHTML: true, maxBytes: 100_000, forceSplit: false)

		#expect(segments.count == 1)
		#expect(segments.first?.content == source)
	}

	@Test func forceSplitBreaksSmallSourceInTwo() {
		let source = (1...4).map { "<p>Paragraph \($0) " + String(repeating: "x", count: 80) + "</p>" }
			.joined(separator: "\n")
		let segments = AIBodySegmenter.segments(source: source, isHTML: true, maxBytes: 100_000, forceSplit: true)

		#expect(segments.count == 2)
		#expect(segments.map(\.content).joined() == source)
	}

	@Test func oversizedSourceIsGroupedUnderTheBudget() {
		let source = (1...6).map { "<p>Paragraph \($0) " + String(repeating: "x", count: 700) + "</p>" }
			.joined(separator: "\n")
		let segments = AIBodySegmenter.segments(source: source, isHTML: true, maxBytes: 1_000, forceSplit: false)

		#expect(segments.count > 1)
		#expect(segments.map(\.content).joined() == source)
	}

	@Test func textSourceSplitsOnBlankLines() {
		let source = (1...4).map { "Paragraph \($0) " + String(repeating: "word ", count: 30) }
			.joined(separator: "\n\n")
		let segments = AIBodySegmenter.segments(source: source, isHTML: false, maxBytes: 100_000, forceSplit: true)

		#expect(segments.count == 2)
		#expect(segments.map(\.content).joined() == source)
	}

	@Test func singleHugeParagraphIsSplitInTwo() {
		let source = String(repeating: "word ", count: 400)
		let segments = AIBodySegmenter.segments(source: source, isHTML: false, maxBytes: 100_000, forceSplit: true)

		#expect(segments.count == 2)
		#expect(segments.map(\.content).joined() == source)
	}

	@Test func segmentKeysAreStable() {
		let source = (1...4).map { "<p>Paragraph \($0)</p>" }.joined(separator: "\n")
		let first = AIBodySegmenter.segments(source: source, isHTML: true, maxBytes: 100_000, forceSplit: true)
		let second = AIBodySegmenter.segments(source: source, isHTML: true, maxBytes: 100_000, forceSplit: true)

		#expect(first.map(\.key) == second.map(\.key))
		#expect(Set(first.map(\.key)).count == first.count)
	}
}
