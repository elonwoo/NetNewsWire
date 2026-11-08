//
//  SourceCatalog.swift
//  NetNewsWire
//

import Foundation

enum SourceEndpoint: Sendable, Equatable {

	case directFeed(URL)
	case rssHub(path: String)
	case weChatCatalog
}

enum SourceRewriteHint: String, Sendable, Equatable {

	case article
	case paper
	case productHunt
}

/// One entry in the built-in source directory.
///
/// The catalog describes how a source is fetched. It does not create accounts
/// or feeds; the app decides when to turn an entry into a subscription.
struct SourceDefinition: Sendable, Equatable, Identifiable {

	let id: String
	let displayName: String
	let endpoint: SourceEndpoint
	let websiteURL: URL?
	let rewriteHint: SourceRewriteHint
	/// Product Hunt needs its product website fetched before rewriting.
	let requiresWebsiteContext: Bool

	/// Every feed URL that can be subscribed to directly. RSSHub entries return
	/// one candidate per instance, in failover order.
	var feedURLs: [URL] {
		switch endpoint {
		case .directFeed(let url):
			return [url]
		case .rssHub(let path):
			return SourceCatalog.rssHubCandidateURLs(for: path)
		case .weChatCatalog:
			return []
		}
	}
}

enum SourceCatalog {

	static let weChatOPMLURL: URL = makeURL("https://raw.githubusercontent.com/ginobefun/BestBlogs/main/BestBlogs_RSS_ALL.opml")

	static let sources: [SourceDefinition] = [
		SourceDefinition(
			id: "x-news",
			displayName: "X News",
			endpoint: .directFeed(makeURL("https://xnews.qiaomu.ai/feed.xml")),
			websiteURL: makeURL("https://xnews.qiaomu.ai"),
			rewriteHint: .article,
			requiresWebsiteContext: false
		),
		SourceDefinition(
			id: "blog",
			displayName: "乔木博客",
			endpoint: .directFeed(makeURL("https://blog.qiaomu.ai/feed.xml")),
			websiteURL: makeURL("https://blog.qiaomu.ai"),
			rewriteHint: .article,
			requiresWebsiteContext: false
		),
		SourceDefinition(
			id: "product-hunt",
			displayName: "Product Hunt",
			endpoint: .directFeed(makeURL("https://www.producthunt.com/feed")),
			websiteURL: makeURL("https://www.producthunt.com"),
			rewriteHint: .productHunt,
			requiresWebsiteContext: true
		),
		SourceDefinition(
			id: "hugging-face-papers",
			displayName: "Hugging Face 每日论文",
			endpoint: .rssHub(path: "/huggingface/daily-papers"),
			websiteURL: makeURL("https://huggingface.co/papers"),
			rewriteHint: .paper,
			requiresWebsiteContext: false
		),
		SourceDefinition(
			id: "wechat-catalog",
			displayName: "微信公众号目录",
			endpoint: .weChatCatalog,
			websiteURL: makeURL("https://bestblogs.dev"),
			rewriteHint: .article,
			requiresWebsiteContext: false
		)
	]

	static func source(id: String) -> SourceDefinition? {
		sources.first { $0.id == id }
	}

	static func rssHubCandidateURLs(for path: String, instances: [RSSHubInstance] = RSSHubInstanceDefaults.all) -> [URL] {
		instances.compactMap { $0.url(for: path) }
	}

	private static func makeURL(_ string: String) -> URL {
		guard let url = URL(string: string) else {
			preconditionFailure("Invalid built-in source URL: \(string)")
		}
		return url
	}
}
