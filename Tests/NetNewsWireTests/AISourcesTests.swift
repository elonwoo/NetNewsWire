//
//  AISourcesTests.swift
//  NetNewsWireTests
//

import Foundation
import XCTest
import RSWeb

@testable import NetNewsWire

final class AISourcesTests: XCTestCase {

	// MARK: - RSSHub

	func testRSSHubFailsOverInOrder() async throws {
		let first = try XCTUnwrap(RSSHubInstance("https://first.example"))
		let second = try XCTUnwrap(RSSHubInstance("https://second.example"))
		let loader = MockSourceLoader { request in
			if request.url.host == "first.example" {
				throw SourceHTTPError.httpStatus(500)
			}
			return SourceHTTPResponse(data: Data("<rss/>".utf8), statusCode: 200, mimeType: "application/xml", finalURL: request.url)
		}

		let client = RSSHubMultiInstanceClient(loader: loader, instances: [first, second])
		let result = try await client.fetch(path: "/huggingface/daily-papers")

		XCTAssertEqual(result.instance.baseURL.host, "second.example")
		XCTAssertEqual(result.attempts.count, 1)
		XCTAssertEqual(result.attempts.first?.instance.baseURL.host, "first.example")
	}

	func testRSSHubTreatsEmptyBodyAsFailure() async throws {
		let first = try XCTUnwrap(RSSHubInstance("https://first.example"))
		let second = try XCTUnwrap(RSSHubInstance("https://second.example"))
		let loader = MockSourceLoader { request in
			if request.url.host == "first.example" {
				return SourceHTTPResponse(data: Data(), statusCode: 200, mimeType: nil, finalURL: request.url)
			}
			return SourceHTTPResponse(data: Data("<rss/>".utf8), statusCode: 200, mimeType: nil, finalURL: request.url)
		}

		let client = RSSHubMultiInstanceClient(loader: loader, instances: [first, second])
		let result = try await client.fetch(path: "/x")

		XCTAssertEqual(result.instance.baseURL.host, "second.example")
		XCTAssertEqual(result.attempts.count, 1)
	}

	func testRSSHubInstanceJoinsPaths() throws {
		let instance = try XCTUnwrap(RSSHubInstance("https://example.com/rsshub/"))
		XCTAssertEqual(instance.url(for: "/huggingface/daily-papers")?.absoluteString, "https://example.com/rsshub/huggingface/daily-papers")
	}

	func testRSSHubThrowsWhenAllInstancesFail() async throws {
		let first = try XCTUnwrap(RSSHubInstance("https://first.example"))
		let second = try XCTUnwrap(RSSHubInstance("https://second.example"))
		let loader = MockSourceLoader { _ in
			throw SourceHTTPError.httpStatus(503)
		}

		let client = RSSHubMultiInstanceClient(loader: loader, instances: [first, second])
		do {
			_ = try await client.fetch(path: "/x")
			XCTFail("Expected all instances to fail")
		} catch let error as RSSHubFetchError {
			guard case .allInstancesFailed(let attempts) = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
			XCTAssertEqual(attempts.count, 2)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	// MARK: - WeChat catalog

	func testWeChatCatalogParsesOPML() throws {
		let opml = """
		<?xml version="1.0" encoding="UTF-8"?>
		<opml version="2.0">
			<head><title>BestBlogs</title></head>
			<body>
				<outline text="AI">
					<outline text="量子位" xmlUrl="https://wechat2rss.bestblogs.dev/feed/a.xml" htmlUrl="https://mp.weixin.qq.com/s/a"/>
					<outline text="Hugging Face Blog" xmlUrl="https://huggingface.co/blog/feed.xml"/>
				</outline>
			</body>
		</opml>
		"""

		let catalog = try WeChatCatalogParser.parse(opmlXML: opml)

		XCTAssertEqual(catalog.title, "BestBlogs")
		XCTAssertEqual(catalog.feeds.count, 2)
		XCTAssertEqual(catalog.weChatFeeds.count, 1)
		XCTAssertEqual(catalog.weChatFeeds.first?.title, "量子位")
		XCTAssertEqual(catalog.weChatFeeds.first?.category, "AI")
		XCTAssertEqual(catalog.weChatFeeds.first?.feedURL.absoluteString, "https://wechat2rss.bestblogs.dev/feed/a.xml")
	}

	// MARK: - WeChat images

	func testWeChatImageRouterRoundTrips() throws {
		let imageURL = "https://mmbiz.qpic.cn/mmbiz_jpg/abc/640?wx_fmt=jpeg&from=appmsg"
		let routed = try XCTUnwrap(WeChatImageRouter.routedURLString(imageURL))
		XCTAssertTrue(routed.hasPrefix("nnwWeChatImage:"))

		let requestURL = try XCTUnwrap(URL(string: routed))
		XCTAssertEqual(WeChatImageRouter.imageURL(from: requestURL)?.absoluteString, imageURL)
		XCTAssertNil(WeChatImageRouter.routedURLString("https://example.com/a.jpg"))
	}

	func testWeChatImageRouterRewritesHTML() {
		let html = #"<p><img src="https://mmbiz.qpic.cn/mmbiz_png/abc/640" data-src="https://mmbiz.qpic.cn/mmbiz_png/def/640"></p>"#
		let rewritten = WeChatImageRouter.rewriteHTML(html)

		XCTAssertFalse(rewritten.contains("https://mmbiz.qpic.cn"))
		XCTAssertEqual(rewritten.components(separatedBy: "nnwWeChatImage:").count - 1, 2)
	}

	// MARK: - YouTube

	func testYouTubeAnchorBecomesNoCookieEmbed() {
		let html = #"<p>Watch <a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">this video</a> now.</p>"#
		let rewritten = YouTubeEmbedRewriter.rewriteHTML(html)

		XCTAssertTrue(rewritten.contains("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"))
		XCTAssertFalse(rewritten.contains("<a href"))
		XCTAssertTrue(rewritten.contains("Watch "))
		XCTAssertTrue(rewritten.contains(" now."))
	}

	func testYouTubeBareURLBecomesEmbed() {
		let html = "<p>https://youtu.be/dQw4w9WgXcQ</p>"
		let rewritten = YouTubeEmbedRewriter.rewriteHTML(html)

		XCTAssertTrue(rewritten.contains("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"))
		XCTAssertFalse(rewritten.contains("youtu.be"))
	}

	func testYouTubeExistingIframeSwitchesToNoCookie() {
		let html = #"<iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>"#
		let rewritten = YouTubeEmbedRewriter.rewriteHTML(html)

		XCTAssertTrue(rewritten.contains("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"))
		XCTAssertFalse(rewritten.contains("https://www.youtube.com/embed"))
	}

	func testYouTubeDuplicateIsEmbeddedOnce() {
		let html = #"<a href="https://youtu.be/dQw4w9WgXcQ">one</a><a href="https://youtu.be/dQw4w9WgXcQ">two</a>"#
		let rewritten = YouTubeEmbedRewriter.rewriteHTML(html)
		let embedCount = rewritten.components(separatedBy: "youtube-nocookie.com/embed/dQw4w9WgXcQ").count - 1

		XCTAssertEqual(embedCount, 1)
		XCTAssertTrue(rewritten.contains(">two</a>"))
	}

	func testYouTubeLeavesOtherLinksAlone() {
		let html = #"<a href="https://example.com/watch?v=dQw4w9WgXcQ">x</a>"#
		XCTAssertEqual(YouTubeEmbedRewriter.rewriteHTML(html), html)
	}

	func testYouTubeBareURLNextToChineseBecomesEmbed() {
		let withPunctuation = YouTubeEmbedRewriter.rewriteHTML("<p>观看https://youtu.be/VIDEOTEST01。</p>")
		XCTAssertTrue(withPunctuation.contains("https://www.youtube-nocookie.com/embed/VIDEOTEST01"))
		XCTAssertFalse(withPunctuation.contains("youtu.be"))
		XCTAssertTrue(withPunctuation.contains("观看"))
		XCTAssertTrue(withPunctuation.contains("。"))

		let withFollowingText = YouTubeEmbedRewriter.rewriteHTML("<p>看 https://youtu.be/VIDEOTEST01。视频</p>")
		XCTAssertTrue(withFollowingText.contains("https://www.youtube-nocookie.com/embed/VIDEOTEST01"))
		XCTAssertFalse(withFollowingText.contains("youtu.be"))
		XCTAssertTrue(withFollowingText.contains("。视频"))
	}

	func testYouTubeBareURLStopsAtNonURLCharacters() {
		let cases: [(suffix: String, preserved: String)] = [
			("〜后续", "〜后续"),
			("・后续", "・后续"),
			("〔测试〕", "〔测试〕"),
			("&nbsp;后续", "&nbsp;后续"),
			("&amp;后继", "&amp;后继"),
			("&#39;后续", "&#39;后续")
		]

		for testCase in cases {
			let rewritten = YouTubeEmbedRewriter.rewriteHTML("<p>看 https://youtu.be/VIDEOTEST01\(testCase.suffix)</p>")
			XCTAssertTrue(rewritten.contains("https://www.youtube-nocookie.com/embed/VIDEOTEST01"), testCase.suffix)
			XCTAssertFalse(rewritten.contains("youtu.be"), testCase.suffix)
			XCTAssertTrue(rewritten.contains(testCase.preserved), testCase.suffix)
		}
	}

	func testYouTubeIgnoresDataHref() {
		let withoutHref = #"<a data-href="https://www.youtube.com/watch?v=VIDEOTEST01">x</a>"#
		XCTAssertEqual(YouTubeEmbedRewriter.rewriteHTML(withoutHref), withoutHref)

		let withSafeHref = #"<a data-href="https://www.youtube.com/watch?v=VIDEOTEST01" href="https://example.com">x</a>"#
		XCTAssertFalse(YouTubeEmbedRewriter.rewriteHTML(withSafeHref).contains("youtube-nocookie.com"))
	}

	func testYouTubeBareURLInStraightQuotesAndAfterEquals() {
		let doubleQuoted = #"<p>Watch "https://youtu.be/VIDEOTEST01" now.</p>"#
		XCTAssertTrue(YouTubeEmbedRewriter.rewriteHTML(doubleQuoted).contains("youtube-nocookie.com/embed/VIDEOTEST01"))

		let singleQuoted = "<p>Watch 'https://youtu.be/VIDEOTEST01' now.</p>"
		XCTAssertTrue(YouTubeEmbedRewriter.rewriteHTML(singleQuoted).contains("youtube-nocookie.com/embed/VIDEOTEST01"))

		let afterEquals = "<p>link=https://youtu.be/VIDEOTEST01</p>"
		XCTAssertTrue(YouTubeEmbedRewriter.rewriteHTML(afterEquals).contains("youtube-nocookie.com/embed/VIDEOTEST01"))

		let attributeOnly = #"<img src="https://www.youtube.com/watch?v=VIDEOTEST01">"#
		XCTAssertEqual(YouTubeEmbedRewriter.rewriteHTML(attributeOnly), attributeOnly)
	}

	func testYouTubeDuplicateIframesAreEmbeddedOnce() {
		let html = #"<iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe><iframe src="https://www.youtube.com/embed/VIDEOTEST01" width="560"></iframe>"#
		let rewritten = YouTubeEmbedRewriter.rewriteHTML(html)

		XCTAssertEqual(rewritten.components(separatedBy: "<iframe").count - 1, 1)
		XCTAssertEqual(rewritten.components(separatedBy: "</iframe>").count - 1, 1)
		XCTAssertFalse(rewritten.lowercased().contains("www.youtube.com/embed"))
		XCTAssertTrue(rewritten.contains("youtube-nocookie.com/embed/VIDEOTEST01"))
	}

	func testYouTubeDuplicateIframeIsRemovedEntirely() {
		let html = #"<p>Before</p><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe><p>After</p>"#
		let rewritten = YouTubeEmbedRewriter.rewriteHTML(html)

		XCTAssertEqual(rewritten.components(separatedBy: "<iframe").count - 1, 1)
		XCTAssertFalse(rewritten.contains("<iframe src=\"https://www.youtube.com"))
		XCTAssertTrue(rewritten.contains("Before"))
		XCTAssertTrue(rewritten.contains("After"))
	}

	func testYouTubeBareURLPeelsDeepEscapedEntities() {
		for suffix in ["&amp;amp;amp;nbsp;", "&amp;amp;amp;amp;nbsp;"] {
			let rewritten = YouTubeEmbedRewriter.rewriteHTML("<p>看 https://youtu.be/VIDEOTEST01\(suffix)后续</p>")
			XCTAssertTrue(rewritten.contains("youtube-nocookie.com/embed/VIDEOTEST01"), suffix)
			XCTAssertFalse(rewritten.contains("youtu.be"), suffix)
			XCTAssertTrue(rewritten.contains("后续"), suffix)
		}
	}

	func testYouTubeAnchorWithUnquotedHrefBecomesEmbed() {
		let html = #"<p>Watch <a href=https://www.youtube.com/watch?v=dQw4w9WgXcQ>this video</a> now.</p>"#
		let rewritten = YouTubeEmbedRewriter.rewriteHTML(html)

		XCTAssertTrue(rewritten.contains("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"))
		XCTAssertFalse(rewritten.contains("<a href"))
		XCTAssertTrue(rewritten.contains("Watch "))
		XCTAssertTrue(rewritten.contains(" now."))
	}

	// MARK: - Product Hunt

	func testProductHuntFeedParsesEntry() throws {
		let atom = """
		<?xml version="1.0" encoding="UTF-8"?>
		<feed xmlns="http://www.w3.org/2005/Atom">
			<title>Product Hunt</title>
			<entry>
				<id>tag:www.producthunt.com,2005:Post/1307984</id>
				<published>2026-11-07T09:52:26-08:00</published>
				<updated>2026-11-08T06:03:02-08:00</updated>
				<link rel="alternate" type="text/html" href="https://www.producthunt.com/products/agent-clan"/>
				<title>Agent Clan</title>
				<content type="html">&lt;p&gt;Command your Claude Code and Codex agents with gestures&lt;/p&gt;&lt;p&gt;&lt;a href="https://www.producthunt.com/r/p/1307984?app_id=339"&gt;Link&lt;/a&gt;&lt;/p&gt;</content>
				<author><name>Someone</name></author>
			</entry>
		</feed>
		"""

		let entries = try ProductHuntFeedParser().parse(atomXML: atom)
		let entry = try XCTUnwrap(entries.first)

		XCTAssertEqual(entry.name, "Agent Clan")
		XCTAssertEqual(entry.tagline, "Command your Claude Code and Codex agents with gestures")
		XCTAssertEqual(entry.discussionURL?.absoluteString, "https://www.producthunt.com/products/agent-clan")
		XCTAssertEqual(entry.websiteURL?.absoluteString, "https://www.producthunt.com/r/p/1307984?app_id=339")
	}

	func testProductHuntFetcherUsesDirectHTMLFirst() async throws {
		let longText = String(repeating: "A useful product description. ", count: 20)
		let html = "<html><head><title>Acme</title></head><body><p>\(longText)</p></body></html>"
		let loader = MockSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let websiteURL = try XCTUnwrap(URL(string: "https://acme.example"))
		let context = try await ProductHuntWebsiteFetcher(loader: loader).fetchContext(websiteURL: websiteURL, productName: "Acme")

		XCTAssertEqual(context.method, .directHTML)
		XCTAssertEqual(context.title, "Acme")
		XCTAssertTrue(context.text.contains("useful product description"))
	}

	func testProductHuntFetcherFallsBackToJina() async throws {
		let jinaText = String(repeating: "Jina body. ", count: 30)
		let loader = MockSourceLoader { request in
			if request.url.host == "acme.example" {
				throw SourceHTTPError.httpStatus(403)
			}
			if request.url.host == "r.jina.ai" {
				return SourceHTTPResponse(data: Data(jinaText.utf8), statusCode: 200, mimeType: "text/plain", finalURL: request.url)
			}
			throw SourceHTTPError.httpStatus(404)
		}
		let websiteURL = try XCTUnwrap(URL(string: "https://acme.example"))
		let context = try await ProductHuntWebsiteFetcher(loader: loader).fetchContext(websiteURL: websiteURL, productName: "Acme")

		XCTAssertEqual(context.method, .jinaReader)
		XCTAssertTrue(context.text.contains("Jina body"))
	}

	func testDuckDuckGoResultParserReadsResults() throws {
		let html = """
		<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Facme.example%2F&amp;rut=abc">Acme</a>
		<a class="result__snippet" href="https://acme.example">Acme makes widgets.</a>
		"""
		let results = DuckDuckGoResultParser.parse(html: html)
		let result = try XCTUnwrap(results.first)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(result.title, "Acme")
		XCTAssertEqual(result.url.absoluteString, "https://acme.example/")
		XCTAssertEqual(result.snippet, "Acme makes widgets.")
	}

	func testJinaProductHuntPageParserFindsVisitWebsiteLink() throws {
		let markdown = """
		# Agent Clan
		[Visit website](https://agentclan.app/?ref=producthunt)
		[X](https://x.com/agentclanapp)
		"""
		let url = try XCTUnwrap(JinaProductHuntPageParser.websiteURL(fromMarkdown: markdown))
		XCTAssertEqual(url.absoluteString, "https://agentclan.app/?ref=producthunt")
	}

	func testProductHuntFetcherThrowsWhenAllMethodsFail() async throws {
		let loader = MockSourceLoader { _ in
			throw SourceHTTPError.httpStatus(500)
		}
		let websiteURL = try XCTUnwrap(URL(string: "https://acme.example"))
		do {
			_ = try await ProductHuntWebsiteFetcher(loader: loader).fetchContext(websiteURL: websiteURL, productName: "Acme")
			XCTFail("Expected all methods to fail")
		} catch let error as ProductHuntFetchError {
			guard case .allMethodsFailed(let url, let attempts) = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
			XCTAssertEqual(url, websiteURL)
			XCTAssertEqual(attempts.count, 3)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	// MARK: - Hugging Face

	func testHuggingFaceFeedParsesCard() throws {
		let rss = """
		<?xml version="1.0" encoding="UTF-8"?>
		<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
			<channel>
				<title>Huggingface Daily Papers</title>
				<link>https://huggingface.co/papers</link>
				<item>
					<title>Muir: Linear Attention</title>
					<description>Linear attention compresses context into a fixed-size state.</description>
					<link>https://arxiv.org/abs/2611.08376</link>
					<guid>https://arxiv.org/abs/2611.08376</guid>
					<pubDate>Thu, 05 Nov 2026 12:53:49 GMT</pubDate>
					<dc:creator>Tushaar Gangavarapu, Gil Tabak</dc:creator>
				</item>
			</channel>
		</rss>
		"""

		let cards = try HuggingFacePaperParser().parse(feedXML: rss)
		let card = try XCTUnwrap(cards.first)

		XCTAssertEqual(card.title, "Muir: Linear Attention")
		XCTAssertEqual(card.arxivID, "2611.08376")
		XCTAssertEqual(card.arxivURL?.absoluteString, "https://arxiv.org/abs/2611.08376")
		XCTAssertEqual(card.authors, ["Gil Tabak", "Tushaar Gangavarapu"])
		XCTAssertTrue(card.abstract.contains("Linear attention"))
		XCTAssertEqual(card.paperURL?.absoluteString, "https://huggingface.co/papers/2611.08376")
	}

	func testHuggingFaceHTMLParsesCard() throws {
		let html = """
		<html><head>
		<meta property="og:title" content="A Paper">
		<meta name="citation_author" content="Alice">
		<meta name="citation_author" content="Bob">
		<meta name="citation_abstract" content="An abstract about attention.">
		</head><body><a href="https://arxiv.org/abs/2501.12345">arXiv</a></body></html>
		"""
		let sourceURL = try XCTUnwrap(URL(string: "https://huggingface.co/papers/2501.12345"))
		let card = try XCTUnwrap(HuggingFacePaperParser().parse(html: html, sourceURL: sourceURL))

		XCTAssertEqual(card.title, "A Paper")
		XCTAssertEqual(card.authors, ["Alice", "Bob"])
		XCTAssertEqual(card.abstract, "An abstract about attention.")
		XCTAssertEqual(card.arxivID, "2501.12345")
		XCTAssertEqual(card.paperID, "2501.12345")
	}

	// MARK: - Catalog

	func testSourceCatalogHasBuiltInSources() throws {
		let names = Set(SourceCatalog.sources.map(\.displayName))
		XCTAssertTrue(names.contains("X News"))
		XCTAssertTrue(names.contains("乔木博客"))
		XCTAssertTrue(names.contains("Product Hunt"))
		XCTAssertTrue(names.contains("Hugging Face 每日论文"))
		XCTAssertTrue(names.contains("微信公众号目录"))

		let xNews = try XCTUnwrap(SourceCatalog.source(id: "x-news"))
		guard case .directFeed(let xNewsURL) = xNews.endpoint else {
			XCTFail("Expected a direct feed")
			return
		}
		XCTAssertEqual(xNewsURL.absoluteString, "https://xnews.qiaomu.ai/feed.xml")

		let blog = try XCTUnwrap(SourceCatalog.source(id: "blog"))
		guard case .directFeed(let blogURL) = blog.endpoint else {
			XCTFail("Expected a direct feed")
			return
		}
		XCTAssertEqual(blogURL.absoluteString, "https://blog.qiaomu.ai/feed.xml")

		let papers = try XCTUnwrap(SourceCatalog.source(id: "hugging-face-papers"))
		XCTAssertEqual(papers.feedURLs.count, RSSHubInstanceDefaults.all.count)
		XCTAssertEqual(papers.feedURLs.first?.absoluteString, "https://rsshub.bestblogs.dev/huggingface/daily-papers")
	}
}

private struct MockSourceLoader: SourceHTTPLoading {

	let handler: @Sendable (SourceHTTPRequest) async throws -> SourceHTTPResponse

	func load(_ request: SourceHTTPRequest) async throws -> SourceHTTPResponse {
		try await handler(request)
	}
}
