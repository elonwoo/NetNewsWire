//
//  AIBodySegmenter.swift
//  NetNewsWire
//

import Foundation

struct AIBodySegment: Sendable, Equatable {
	let key: String
	let content: String
	let isHTML: Bool
}

/// Splits article content into coarse pieces so a failed body translation can
/// resume without redoing the whole article.
///
/// This is not the engine's token-budget chunking. The engine still receives
/// each segment and decides internally how to batch it. Segments exist only to
/// make successful work durable.
enum AIBodySegmenter {

	static func segments(source: String, isHTML: Bool, maxBytes: Int, forceSplit: Bool) -> [AIBodySegment] {
		guard !source.isEmpty else {
			return []
		}

		let budget = max(1000, maxBytes)
		var units = splitUnits(source, isHTML: isHTML)
		if units.isEmpty {
			units = [source]
		}
		if forceSplit, units.count == 1, !isHTML {
			// A single HTML block must stay whole: splitting inside a tag would
			// corrupt the fragment. The engine sends it as one oversized request.
			units = splitInHalf(units[0])
		}

		let groups: [String]
		if forceSplit, units.count > 1, units.reduce(0, { $0 + $1.utf8.count }) <= budget {
			let middle = units.count / 2
			groups = [
				units[0..<middle].joined(),
				units[middle...].joined()
			].filter { !$0.isEmpty }
		} else if !forceSplit, source.utf8.count <= budget {
			groups = [source]
		} else {
			groups = group(units, budget: budget)
		}

		return groups.enumerated().map { index, content in
			makeSegment(index: index, content: content, isHTML: isHTML)
		}
	}

	static func makeSegment(index: Int, content: String, isHTML: Bool) -> AIBodySegment {
		let digest = AIContentHash.sha256Hex(content).prefix(16)
		return AIBodySegment(key: "\(index)-b2-\(digest)-\(content.utf8.count)", content: content, isHTML: isHTML)
	}
}

private extension AIBodySegmenter {

	static func group(_ units: [String], budget: Int) -> [String] {
		var groups: [String] = []
		var current = ""
		for unit in units {
			if !current.isEmpty, current.utf8.count + unit.utf8.count > budget {
				groups.append(current)
				current = unit
			} else {
				current += unit
			}
			// An oversized unit is kept whole: splitting it could cut a tag in
			// half. The engine's caller treats truncation as recoverable.
		}
		if !current.isEmpty {
			groups.append(current)
		}
		return groups
	}

	static func splitUnits(_ source: String, isHTML: Bool) -> [String] {
		let boundaries = isHTML ? htmlBoundaries(source) : paragraphBoundaries(source)
		guard !boundaries.isEmpty else {
			// No safe boundary: keep the whole source as one unit rather than
			// cutting inside a tag.
			return isHTML ? [] : [source]
		}

		var units: [String] = []
		var start = source.startIndex
		for boundary in boundaries where boundary > start {
			units.append(String(source[start..<boundary]))
			start = boundary
		}
		if start < source.endIndex {
			units.append(String(source[start...]))
		}
		return units
	}

	static func paragraphBoundaries(_ source: String) -> [String.Index] {
		var boundaries: [String.Index] = []
		var searchStart = source.startIndex
		while let range = source.range(of: "\n\n", range: searchStart..<source.endIndex) {
			boundaries.append(range.upperBound)
			searchStart = range.upperBound
		}
		return boundaries
	}

	static func htmlBoundaries(_ source: String) -> [String.Index] {
		let pattern = #"</(?:p|h[1-6]|li|blockquote|pre|figure|table)>"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
			return []
		}
		let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
		var boundaries: [String.Index] = []
		for match in regex.matches(in: source, range: fullRange) {
			guard let boundary = Range(match.range, in: source)?.upperBound else {
				continue
			}
			boundaries.append(boundary)
		}
		return boundaries
	}

	static func splitInHalf(_ content: String) -> [String] {
		guard content.utf8.count >= 200 else {
			return [content]
		}

		let middleOffset = content.count / 2
		let middle = content.index(content.startIndex, offsetBy: middleOffset)

		if let paragraph = content.range(of: "\n\n", options: .backwards, range: content.startIndex..<middle) {
			return halves(content, at: paragraph.upperBound)
		}
		if let paragraph = content.range(of: "\n\n", range: middle..<content.endIndex) {
			return halves(content, at: paragraph.upperBound)
		}
		if let space = content.range(of: " ", options: .backwards, range: content.startIndex..<middle) {
			return halves(content, at: space.upperBound)
		}
		return halves(content, at: middle)
	}

	static func halves(_ content: String, at index: String.Index) -> [String] {
		guard index > content.startIndex, index < content.endIndex else {
			return [content]
		}
		let head = String(content[content.startIndex..<index])
		let tail = String(content[index...])
		guard !head.isEmpty, !tail.isEmpty else {
			return [content]
		}
		return [head, tail]
	}
}
