//
//  MainContentExtractor.swift
//  AI
//

import Foundation

/// Extracts the main article body from a web page using the forgiving HTML
/// parser shared with the rewrite and translation pipelines.
///
/// The extractor only reads the parsed tree; it never touches the network.
public enum MainContentExtractor {

	public static func mainContentHTML(from html: String) -> String? {
		guard !html.isEmpty else {
			return nil
		}
		let tokens = HTMLSourceBlocks.tokenize(Array(html))
		let cleaned = HTMLSourceBlocks.dropActiveContent(tokens)
		let root = HTMLSourceBlocks.buildTree(cleaned)
		pruneChrome(in: root, insideMain: false)

		if let best = bestCandidate(in: root), best.textLength >= 600 {
			let rendered = renderChildren(of: best.node)
			if !rendered.isEmpty {
				return rendered
			}
		}
		return fallbackHTML(in: root)
	}

	// MARK: - Tree cleanup

	private static let chromeTags: Set<String> = ["nav", "aside", "footer"]
	private static let candidateTags: Set<String> = ["article", "main", "section", "div"]
	private static let paragraphTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "li"]

	private static let positiveHints = ["article", "post", "content", "entry", "body"]
	private static let disqualifyingExactTokens: Set<String> = ["ad", "ads"]
	private static let disqualifyingPrefixTokens = [
		"comment", "footer", "nav", "sidebar", "share", "related", "newsletter", "subscribe",
		"promo", "signup", "cta", "advert", "sponsor", "cookie", "breadcrumb", "pagination", "pager"
	]

	/// Drops page chrome by tag and by class/id hint. A header survives only when
	/// it sits inside an article or a main element.
	private static func pruneChrome(in node: HTMLSourceBlocks.ParsedNode, insideMain: Bool) {
		var kept: [HTMLSourceBlocks.ParsedNode] = []
		for child in node.children {
			guard let tag = child.tag else {
				kept.append(child)
				continue
			}
			if isDisqualified(child) || chromeTags.contains(tag) {
				continue
			}
			if tag == "header" && !insideMain {
				continue
			}
			let childInsideMain = insideMain || tag == "article" || tag == "main"
			pruneChrome(in: child, insideMain: childInsideMain)
			kept.append(child)
		}
		node.children = kept
	}

	private static func isDisqualified(_ node: HTMLSourceBlocks.ParsedNode) -> Bool {
		let hints = hintText(of: node)
		guard !hints.isEmpty else {
			return false
		}
		let tokens = hints
			.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
			.map(String.init)
		if tokens.contains(where: disqualifyingExactTokens.contains) {
			return true
		}
		if tokens.contains(where: { token in
			disqualifyingPrefixTokens.contains(where: token.hasPrefix)
		}) {
			return true
		}
		// Catches hyphenated hints such as "sign-up" and "bread-crumbs".
		let compact = tokens.joined()
		return disqualifyingPrefixTokens.contains { term in
			term.count >= 5 && compact.contains(term)
		}
	}

	// MARK: - Candidates

	private struct Candidate {
		let node: HTMLSourceBlocks.ParsedNode
		let textLength: Int
		let score: Int
	}

	private static func bestCandidate(in root: HTMLSourceBlocks.ParsedNode) -> Candidate? {
		var best: Candidate?
		let visit: (HTMLSourceBlocks.ParsedNode) -> Void = { node in
			guard isCandidate(node), linkDensity(of: node) <= 0.6 else {
				return
			}
			let text = candidateTextLength(of: node)
			let candidate = Candidate(node: node, textLength: text, score: score(of: node, textLength: text))
			if candidate.score > (best?.score ?? Int.min) {
				best = candidate
			}
		}
		for extractionRoot in extractionRoots(in: root) {
			walk(extractionRoot, visit: visit)
		}
		return best
	}

	/// When the page declares an article or main landmark, section/div
	/// heuristics could pick a comments or footer block instead. Restrict
	/// extraction to the declared containers and everything inside them.
	private static func extractionRoots(in root: HTMLSourceBlocks.ParsedNode) -> [HTMLSourceBlocks.ParsedNode] {
		var roots: [HTMLSourceBlocks.ParsedNode] = []
		func visit(_ node: HTMLSourceBlocks.ParsedNode) {
			if isPreferredContainer(node) {
				roots.append(node)
				return
			}
			for child in node.children {
				visit(child)
			}
		}
		visit(root)
		return roots.isEmpty ? [root] : roots
	}

	private static func isPreferredContainer(_ node: HTMLSourceBlocks.ParsedNode) -> Bool {
		if let tag = node.tag, tag == "article" || tag == "main" {
			return true
		}
		return node.attribute(["role"])?.lowercased() == "main"
	}

	private static func walk(_ node: HTMLSourceBlocks.ParsedNode, visit: (HTMLSourceBlocks.ParsedNode) -> Void) {
		visit(node)
		for child in node.children {
			walk(child, visit: visit)
		}
	}

	private static func isCandidate(_ node: HTMLSourceBlocks.ParsedNode) -> Bool {
		if let tag = node.tag, candidateTags.contains(tag) {
			return true
		}
		return node.attribute(["role"])?.lowercased() == "main"
	}

	/// Visible text of the paragraph-level descendants that belong to this
	/// candidate rather than to one of its nested candidates.
	private static func candidateTextLength(of node: HTMLSourceBlocks.ParsedNode) -> Int {
		var total = 0
		func walkChildren(_ parent: HTMLSourceBlocks.ParsedNode) {
			for child in parent.children {
				guard let tag = child.tag else {
					continue
				}
				if paragraphTags.contains(tag) {
					total += visibleTextLength(of: child)
					continue
				}
				if isCandidate(child) {
					continue
				}
				walkChildren(child)
			}
		}
		walkChildren(node)
		return total
	}

	private static func visibleTextLength(of node: HTMLSourceBlocks.ParsedNode) -> Int {
		let all = characterCount(HTMLSourceBlocks.plainText(nodes: [node]))
		return max(0, all - linkedTextLength(in: node))
	}

	private static func linkedTextLength(in node: HTMLSourceBlocks.ParsedNode) -> Int {
		var total = 0
		func walkChildren(_ parent: HTMLSourceBlocks.ParsedNode) {
			for child in parent.children {
				guard let tag = child.tag else {
					continue
				}
				if tag == "a" {
					total += characterCount(HTMLSourceBlocks.plainText(nodes: [child]))
					continue
				}
				walkChildren(child)
			}
		}
		walkChildren(node)
		return total
	}

	private static func linkDensity(of node: HTMLSourceBlocks.ParsedNode) -> Double {
		let total = characterCount(HTMLSourceBlocks.plainText(nodes: node.children))
		guard total > 0 else {
			return 0
		}
		return Double(linkedTextLength(in: node)) / Double(total)
	}

	private static func score(of node: HTMLSourceBlocks.ParsedNode, textLength: Int) -> Int {
		var result = textLength
		let hints = hintText(of: node)
		if positiveHints.contains(where: hints.contains) {
			result += 200
		}
		return result
	}

	private static func hintText(of node: HTMLSourceBlocks.ParsedNode) -> String {
		node.attributes
			.filter { $0.name == "class" || $0.name == "id" }
			.compactMap(\.value)
			.joined(separator: " ")
			.lowercased()
	}

	// MARK: - Output

	private static func renderChildren(of node: HTMLSourceBlocks.ParsedNode) -> String {
		node.children.map(HTMLSourceBlocks.render).joined()
	}

	/// Used when no container holds enough text. Collects the outermost
	/// paragraph-level nodes so a page made only of loose paragraphs still
	/// yields something usable.
	private static func fallbackHTML(in root: HTMLSourceBlocks.ParsedNode) -> String? {
		var pieces: [String] = []
		func walkChildren(_ parent: HTMLSourceBlocks.ParsedNode) {
			for child in parent.children {
				guard let tag = child.tag else {
					continue
				}
				if paragraphTags.contains(tag) {
					let text = HTMLSourceBlocks.plainText(nodes: [child])
					let hasMedia = child.children.contains { $0.tag == "img" }
					if !text.isEmpty || hasMedia {
						pieces.append(HTMLSourceBlocks.render(child))
					}
					continue
				}
				walkChildren(child)
			}
		}
		for extractionRoot in extractionRoots(in: root) {
			walkChildren(extractionRoot)
		}
		return pieces.isEmpty ? nil : pieces.joined()
	}

	private static func characterCount(_ text: String) -> Int {
		text.reduce(0) { count, character in
			character.isWhitespace ? count : count + 1
		}
	}
}
