//
//  AIRewriteKindSelector.swift
//  NetNewsWire
//

import AI
import Foundation

enum AIRewriteKind: Sendable, Equatable {
	case article
	case paper
	case productHunt

	var engineKind: RewriteKind {
		switch self {
		case .article:
			return .article
		case .paper:
			return .paper
		case .productHunt:
			return .productHunt
		}
	}
}

enum AIRewriteKindSelector {

	static func kind(for article: AIArticle) -> AIRewriteKind {
		kind(url: article.url, feedID: article.feedID)
	}

	static func kind(url: String?, feedID: String?) -> AIRewriteKind {
		if let url, let host = host(for: url) {
			return kind(forHost: host)
		}
		if let feedID, let host = host(for: feedID) {
			return kind(forHost: host)
		}
		return .article
	}

	private static func kind(forHost host: String) -> AIRewriteKind {
		if isPaperHost(host) {
			return .paper
		}
		if isProductHuntHost(host) {
			return .productHunt
		}
		return .article
	}
}

private extension AIRewriteKindSelector {

	static func host(for value: String) -> String? {
		guard let url = URL(string: value) else {
			return nil
		}
		return url.host?.lowercased()
	}

	static func isPaperHost(_ host: String) -> Bool {
		host == "arxiv.org" || host.hasSuffix(".arxiv.org")
			|| host == "huggingface.co" || host.hasSuffix(".huggingface.co")
	}

	static func isProductHuntHost(_ host: String) -> Bool {
		host == "producthunt.com" || host.hasSuffix(".producthunt.com")
	}
}
