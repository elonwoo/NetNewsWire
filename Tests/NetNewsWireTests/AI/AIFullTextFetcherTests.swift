//
//  AIFullTextFetcherTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import XCTest

@testable import NetNewsWire

final class AIFullTextFetcherTests: XCTestCase {

	func testFetchesAndExtractsMainContent() async throws {
		let article = feedArticle(id: "success", contentText: paragraph("Full page body"))
		let html = page(body: "<article><h1>Full page</h1><p>\(paragraph("Full page body"))</p><p>\(paragraph("More page body"))</p><p>\(paragraph("Third page body"))</p></article>")
		let loader = StubSourceLoader { request in
			XCTAssertEqual(request.url.host, "example.com")
			return SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)
		let enriched = try XCTUnwrap(enrichedArticle(from: outcome))

		XCTAssertEqual(enriched.id, article.id)
		XCTAssertEqual(enriched.title, article.title)
		XCTAssertEqual(enriched.url, article.url)
		XCTAssertEqual(enriched.feedID, article.feedID)
		XCTAssertEqual(enriched.publishedAt, article.publishedAt)
		XCTAssertNil(enriched.contentText)
		let extracted = try XCTUnwrap(enriched.contentHTML)
		XCTAssertTrue(extracted.contains("Full page body"))
		XCTAssertTrue(extracted.contains("More page body"))
	}

	func testAcceptsXHTMLMimeType() async throws {
		let article = feedArticle(id: "xhtml", contentText: paragraph("XHTML body"))
		let html = page(body: "<article><p>\(paragraph("XHTML body"))</p><p>\(paragraph("More XHTML body"))</p><p>\(paragraph("Third XHTML body"))</p></article>")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "application/xhtml+xml; charset=utf-8", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)
		let enriched = try XCTUnwrap(enrichedArticle(from: outcome))

		XCTAssertTrue(try XCTUnwrap(enriched.contentHTML).contains("XHTML body"))
	}

	func testRejectsNonHTMLMimeType() async {
		let article = feedArticle(id: "pdf")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data("not html".utf8), statusCode: 200, mimeType: "application/pdf", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "网页不是 HTML")
	}

	func testRejectsNon2xxResponse() async {
		let article = feedArticle(id: "status")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data("<html><body>Error</body></html>".utf8), statusCode: 500, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "网页返回状态码 500")
	}

	func testRejectsResponseOverFiveMegabytes() async {
		let article = feedArticle(id: "huge")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(
				data: Data(repeating: 0x61, count: AIFullTextFetcher.maximumResponseBytes + 1),
				statusCode: 200,
				mimeType: "text/html",
				finalURL: request.url
			)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "网页超过 5 MB")
	}

	func testRejectsExtractionThatIsNotLongerThanTheFeed() async {
		let article = feedArticle(id: "teaser", contentText: String(repeating: "a", count: 500))
		let html = page(body: "<article><p>\(String(repeating: "b", count: 500))</p></article>")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "提取结果没有比摘要更长")
	}

	func testRejectsTeaserPlusNewsletterGrowth() async {
		let article = feedArticle(id: "growth", contentText: String(repeating: "a", count: 475))
		let html = page(body: """
		<article><p>\(String(repeating: "b", count: 475))</p><p>\(String(repeating: "c", count: 555))</p></article>
		""")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "提取结果没有比摘要更长")
	}

	func testRejectsLongPageThatDoesNotContainTheFeedBody() async {
		let article = feedArticle(id: "unrelated")
		let html = page(body: "<article><p>\(paragraph("Unrelated page body"))</p><p>\(paragraph("More unrelated page body"))</p></article>")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "页面内容与摘要不一致")
	}

	func testRejectsResponsesListNextToTheArticle() async {
		let article = feedArticle(id: "responses", contentText: "Teaser text.")
		let html = page(body: """
		<article><p>\(paragraph("Teaser text"))</p></article>
		<div id="responses"><p>\(paragraph("Reader response"))</p><p>\(paragraph("Another reader response"))</p></div>
		""")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertNotNil(unavailableReason(outcome))
	}

	func testRejectsSiteInfoBlockThatDoesNotContainTheFeedBody() async {
		let article = feedArticle(id: "siteinfo")
		let html = page(body: """
		<div id="siteinfo"><p>\(paragraph("Site information"))</p><p>\(paragraph("More site information"))</p></div>
		""")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "页面内容与摘要不一致")
	}

	func testAcceptsPageThatLegitimatelyContainsTheTeaser() async throws {
		let teaser = "Teaser sentence that also starts the page."
		let article = feedArticle(id: "legitimate", contentText: teaser)
		let html = page(body: """
		<article><p>\(teaser)</p><p>\(paragraph("Full article body"))</p><p>\(paragraph("More article body"))</p></article>
		""")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)
		let enriched = try XCTUnwrap(enrichedArticle(from: outcome))

		XCTAssertTrue(try XCTUnwrap(enriched.contentHTML).contains("Full article body"))
	}

	func testRedirectedResponseStillEnforcesStatusMimeAndSizeChecks() async throws {
		let article = feedArticle(id: "redirect")
		let redirected = try XCTUnwrap(URL(string: "https://cdn.example.net/final"))

		let statusLoader = StubSourceLoader { _ in
			SourceHTTPResponse(data: Data("<html><body>Error</body></html>".utf8), statusCode: 500, mimeType: "text/html", finalURL: redirected)
		}
		let statusOutcome = await AIFullTextFetcher(loader: statusLoader).enrichedArticle(for: article)
		XCTAssertEqual(unavailableReason(statusOutcome), "网页返回状态码 500")

		let mimeLoader = StubSourceLoader { _ in
			SourceHTTPResponse(data: Data("not html".utf8), statusCode: 200, mimeType: "application/pdf", finalURL: redirected)
		}
		let mimeOutcome = await AIFullTextFetcher(loader: mimeLoader).enrichedArticle(for: article)
		XCTAssertEqual(unavailableReason(mimeOutcome), "网页不是 HTML")

		let sizeLoader = StubSourceLoader { _ in
			SourceHTTPResponse(
				data: Data(repeating: 0x61, count: AIFullTextFetcher.maximumResponseBytes + 1),
				statusCode: 200,
				mimeType: "text/html",
				finalURL: redirected
			)
		}
		let sizeOutcome = await AIFullTextFetcher(loader: sizeLoader).enrichedArticle(for: article)
		XCTAssertEqual(unavailableReason(sizeOutcome), "网页超过 5 MB")
	}

	func testRejectsTooShortFeedBodyWithoutFetching() async {
		let article = feedArticle(id: "tiny", contentText: "News")
		let loader = StubSourceLoader { _ in
			XCTFail("A body with fewer than five alphanumeric characters must not fetch")
			throw SourceHTTPError.invalidResponse
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "原文过短，已跳过改写")
	}

	func testFiveAlphanumericCharactersAreStillUsable() async throws {
		let article = feedArticle(id: "five", contentText: "ABCDE")
		let html = page(body: """
		<article><p>ABCDE \(paragraph("Full body"))</p><p>\(paragraph("More body"))</p></article>
		""")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(data: Data(html.utf8), statusCode: 200, mimeType: "text/html", finalURL: request.url)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertNotNil(enrichedArticle(from: outcome))
	}

	func testRejectsPageWithUnreadableEncoding() async {
		let article = feedArticle(id: "gbk")
		let loader = StubSourceLoader { request in
			SourceHTTPResponse(
				data: Data((0..<200).map { _ in UInt8(0xC4) }),
				statusCode: 200,
				mimeType: "text/html",
				finalURL: request.url
			)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		XCTAssertEqual(unavailableReason(outcome), "页面编码无法识别")
	}

	func testFetchErrorBecomesUnavailable() async {
		let article = feedArticle(id: "error")
		let loader = StubSourceLoader { _ in
			throw SourceHTTPError.httpStatus(500)
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let outcome = await fetcher.enrichedArticle(for: article)

		let reason = try? XCTUnwrap(unavailableReason(outcome))
		XCTAssertTrue(reason?.hasPrefix("获取网页失败") == true)
	}

	func testPaperAndProductHuntAreNotApplicable() async {
		let loader = StubSourceLoader { _ in
			XCTFail("Non-article kinds must not fetch")
			throw SourceHTTPError.invalidResponse
		}
		let fetcher = AIFullTextFetcher(loader: loader)
		let paper = AIArticle(id: "paper", title: "Paper", contentText: "Short", url: "https://arxiv.org/abs/2501.00001")
		let product = AIArticle(id: "product", title: "Product", contentText: "Short", url: "https://www.producthunt.com/posts/thing")

		let paperOutcome = await fetcher.enrichedArticle(for: paper)
		let productOutcome = await fetcher.enrichedArticle(for: product)

		XCTAssertEqual(paperOutcome, .notApplicable)
		XCTAssertEqual(productOutcome, .notApplicable)
	}

	func testSummaryPolicyUsesNonWhitespaceCharacterCount() async {
		let loader = StubSourceLoader { _ in
			XCTFail("The summary check must not fetch")
			throw SourceHTTPError.invalidResponse
		}
		let fetcher = AIFullTextFetcher(loader: loader)

		let eightHundred = await fetcher.isLikelySummary(feedArticle(id: "800", contentText: String(repeating: "a", count: 800)))
		let fourteenNinetyNine = await fetcher.isLikelySummary(feedArticle(id: "1499", contentText: String(repeating: "a", count: 1499)))
		let fifteenHundred = await fetcher.isLikelySummary(feedArticle(id: "1500", contentText: String(repeating: "a", count: 1500)))

		XCTAssertTrue(eightHundred)
		XCTAssertTrue(fourteenNinetyNine)
		XCTAssertFalse(fifteenHundred)
	}
}

private extension AIFullTextFetcherTests {

	func feedArticle(id: String, contentText: String = "Short feed summary.") -> AIArticle {
		AIArticle(
			id: id,
			title: "English title",
			contentText: contentText,
			url: "https://example.com/\(id)",
			feedID: "feed",
			publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
	}

	func page(body: String) -> String {
		"""
		<html><head><title>Example</title></head><body>
		<header><h1>Example site</h1></header>
		<nav><a href="/one">Navigation one</a> <a href="/two">Navigation two</a></nav>
		\(body)
		<footer>Footer copyright notice</footer>
		</body></html>
		"""
	}

	func paragraph(_ prefix: String) -> String {
		prefix + " " + String(repeating: "content ", count: 80)
	}

	func enrichedArticle(from outcome: AIFullTextOutcome) -> AIArticle? {
		guard case .enriched(let article) = outcome else {
			return nil
		}
		return article
	}

	func unavailableReason(_ outcome: AIFullTextOutcome) -> String? {
		guard case .unavailable(let reason) = outcome else {
			return nil
		}
		return reason
	}
}

private struct StubSourceLoader: SourceHTTPLoading {

	let handler: @Sendable (SourceHTTPRequest) async throws -> SourceHTTPResponse

	func load(_ request: SourceHTTPRequest) async throws -> SourceHTTPResponse {
		try await handler(request)
	}
}
