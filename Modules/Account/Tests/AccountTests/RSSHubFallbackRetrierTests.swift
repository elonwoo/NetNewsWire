//
//  RSSHubFallbackRetrierTests.swift
//  AccountTests
//

import Foundation
import XCTest
import RSCore
import RSWeb

@testable import Account

@MainActor final class RSSHubFallbackRetrierTests: XCTestCase {

	private let original = "https://rsshub.app/huggingface/daily-papers"
	private let firstInstance = "https://first.example"
	private let secondInstance = "https://second.example"
	private let thirdInstance = "https://third.example"

	private func makeRetrier(loader: any RSSHubFallbackLoading, instances: [String]) throws -> RSSHubFallbackRetrier {
		let parsed = try instances.map { try XCTUnwrap(RSSHubInstance($0)) }
		return RSSHubFallbackRetrier(loader: loader, instances: parsed)
	}

	func testCandidatesSkipOriginalHost() throws {
		let retrier = try makeRetrier(loader: NoopLoader(), instances: [original, firstInstance, secondInstance])
		let feedURL = try XCTUnwrap(URL(string: original))
		let candidates = retrier.candidateURLs(for: feedURL)

		XCTAssertEqual(candidates.map(\.absoluteString), [
			"https://first.example/huggingface/daily-papers",
			"https://second.example/huggingface/daily-papers"
		])
	}

	func testCandidatesKeepInstancePathPrefix() throws {
		let retrier = try makeRetrier(loader: NoopLoader(), instances: [original, "https://mirror.example/rsshub/"])
		let feedURL = try XCTUnwrap(URL(string: original))
		let candidates = retrier.candidateURLs(for: feedURL)

		XCTAssertEqual(candidates.map(\.absoluteString), ["https://mirror.example/rsshub/huggingface/daily-papers"])
	}

	func testCandidatesKeepQuery() throws {
		let retrier = try makeRetrier(loader: NoopLoader(), instances: [original, "https://mirror.example/rsshub"])
		let feedURL = try XCTUnwrap(URL(string: "https://rsshub.app/huggingface/daily-papers?limit=20&lang=zh"))
		let candidates = retrier.candidateURLs(for: feedURL)

		XCTAssertEqual(candidates.map(\.absoluteString), ["https://mirror.example/rsshub/huggingface/daily-papers?limit=20&lang=zh"])
	}

	func testNonRSSHubFeedHasNoCandidates() async throws {
		let retrier = try makeRetrier(loader: NoopLoader(), instances: [original, firstInstance])
		let feedURL = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))

		XCTAssertTrue(retrier.candidateURLs(for: feedURL).isEmpty)

		do {
			_ = try await retrier.fetch(feedURL: feedURL)
			XCTFail("Expected noCandidates")
		} catch let error as RSSHubFallbackError {
			XCTAssertEqual(error, .noCandidates)
		}
	}

	func testStopsAfterFirstSuccess() async throws {
		let recorder = URLRecorder()
		let loader = MockLoader { url in
			await recorder.record(url)
			if url.host == "first.example" {
				throw URLError(.badServerResponse)
			}
			return RSSHubFallbackResponse(data: Data("<rss/>".utf8), statusCode: 200, url: url)
		}
		let retrier = try makeRetrier(loader: loader, instances: [original, firstInstance, secondInstance, thirdInstance])

		let result = try await retrier.fetch(feedURL: try XCTUnwrap(URL(string: original)))

		XCTAssertEqual(result.url.absoluteString, "https://second.example/huggingface/daily-papers")
		let urls = await recorder.urls
		XCTAssertEqual(urls.map(\.host), ["first.example", "second.example"])
	}

	func testAllCandidatesFailCollectsEveryAttempt() async throws {
		let loader = MockLoader { _ in
			throw URLError(.cannotConnectToHost)
		}
		let retrier = try makeRetrier(loader: loader, instances: [original, firstInstance, secondInstance])

		do {
			_ = try await retrier.fetch(feedURL: try XCTUnwrap(URL(string: original)))
			XCTFail("Expected allCandidatesFailed")
		} catch let error as RSSHubFallbackError {
			guard case .allCandidatesFailed(let attempts) = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
			XCTAssertEqual(attempts.map(\.url.absoluteString), [
				"https://first.example/huggingface/daily-papers",
				"https://second.example/huggingface/daily-papers"
			])
		}
	}

	func testEmptyBodyFailsCandidate() async throws {
		let recorder = URLRecorder()
		let loader = MockLoader { url in
			await recorder.record(url)
			if url.host == "first.example" {
				return RSSHubFallbackResponse(data: Data(), statusCode: 200, url: url)
			}
			return RSSHubFallbackResponse(data: Data("<rss/>".utf8), statusCode: 200, url: url)
		}
		let retrier = try makeRetrier(loader: loader, instances: [original, firstInstance, secondInstance])

		let result = try await retrier.fetch(feedURL: try XCTUnwrap(URL(string: original)))

		XCTAssertEqual(result.url.absoluteString, "https://second.example/huggingface/daily-papers")
		let urls = await recorder.urls
		XCTAssertEqual(urls.map(\.host), ["first.example", "second.example"])
	}

	func testNonSuccessStatusFailsCandidate() async throws {
		let loader = MockLoader { url in
			if url.host == "first.example" {
				return RSSHubFallbackResponse(data: Data("<rss/>".utf8), statusCode: 500, url: url)
			}
			return RSSHubFallbackResponse(data: Data("<rss/>".utf8), statusCode: 200, url: url)
		}
		let retrier = try makeRetrier(loader: loader, instances: [original, firstInstance, secondInstance])

		let result = try await retrier.fetch(feedURL: try XCTUnwrap(URL(string: original)))
		XCTAssertEqual(result.url.absoluteString, "https://second.example/huggingface/daily-papers")
	}
}

// MARK: - Refresher integration

@MainActor final class RSSHubFallbackRefresherTests: XCTestCase {

	private var accounts = [Account]()

	override func tearDown() async throws {
		for account in accounts {
			TestAccountManager.shared.deleteAccount(account)
		}
		accounts.removeAll()
		try await super.tearDown()
	}

	func testNormalSuccessStillStoresConditionalGetAndCacheControlInfo() throws {
		let account = TestAccountManager.shared.createAccount(type: .onMyMac)
		accounts.append(account)
		let feedURL = "https://rsshub.app/huggingface/daily-papers"
		let feed = account.createFeed(with: nil, url: feedURL, feedID: feedURL, homePageURL: nil)
		let data = Data("<rss/>".utf8)
		feed.contentHash = data.md5String

		let url = try XCTUnwrap(URL(string: feedURL))
		let response = try XCTUnwrap(HTTPURLResponse(url: url,
													 statusCode: 200,
													 httpVersion: nil,
													 headerFields: ["ETag": "\"abc\"", "Cache-Control": "max-age=300"]))
		let refresher = LocalAccountRefresher()

		refresher.handleDownloadCompletion(feed: feed,
										   url: url,
										   response: response,
										   data: data,
										   error: nil,
										   generation: refresher.currentRefreshGeneration)

		XCTAssertNotNil(feed.conditionalGetInfo)
		XCTAssertNotNil(feed.cacheControlInfo)
		XCTAssertEqual(feed.lastResponseCode, 200)
		XCTAssertEqual(refresher.refreshStatsSnapshot.outstandingParseTasks, 0)
		XCTAssertEqual(feed.contentHash, data.md5String)
	}

	func testFallbackSuccessSkipsInstanceCacheMetadataAndWritesContentHash() async throws {
		let account = TestAccountManager.shared.createAccount(type: .onMyMac)
		accounts.append(account)
		let feedURL = "https://rsshub.app/huggingface/daily-papers"
		let feed = account.createFeed(with: nil, url: feedURL, feedID: feedURL, homePageURL: nil)
		let data = Data(minimalRSS.utf8)
		feed.contentHash = nil
		feed.conditionalGetInfo = nil
		feed.cacheControlInfo = nil
		let refresher = LocalAccountRefresher()

		refresher.handleRSSHubFallbackSuccess(feed: feed,
											  originalURL: try XCTUnwrap(URL(string: feedURL)),
											  data: data,
											  generation: refresher.currentRefreshGeneration)

		var spins = 0
		while refresher.refreshStatsSnapshot.outstandingParseTasks > 0 && spins < 1000 {
			await Task.yield()
			spins += 1
		}

		XCTAssertNil(feed.conditionalGetInfo)
		XCTAssertNil(feed.cacheControlInfo)
		XCTAssertEqual(feed.lastResponseCode, 200)
		XCTAssertNotNil(feed.lastCheckDate)
		XCTAssertEqual(feed.contentHash, data.md5String)
		XCTAssertEqual(refresher.refreshStatsSnapshot.outstandingParseTasks, 0)
	}

	func testFallbackSuccessWithSameHashShortCircuits() throws {
		let account = TestAccountManager.shared.createAccount(type: .onMyMac)
		accounts.append(account)
		let feedURL = "https://rsshub.app/huggingface/daily-papers"
		let feed = account.createFeed(with: nil, url: feedURL, feedID: feedURL, homePageURL: nil)
		let data = Data("<rss/>".utf8)
		feed.contentHash = data.md5String
		feed.conditionalGetInfo = nil
		feed.cacheControlInfo = nil
		let refresher = LocalAccountRefresher()

		refresher.handleRSSHubFallbackSuccess(feed: feed,
											  originalURL: try XCTUnwrap(URL(string: feedURL)),
											  data: data,
											  generation: refresher.currentRefreshGeneration)

		XCTAssertNil(feed.conditionalGetInfo)
		XCTAssertNil(feed.cacheControlInfo)
		XCTAssertEqual(feed.lastResponseCode, 200)
		XCTAssertEqual(feed.contentHash, data.md5String)
		let stats = refresher.refreshStatsSnapshot
		XCTAssertEqual(stats.outstandingParseTasks, 0)
		XCTAssertEqual(stats.newArticlesCount, 0)
		XCTAssertEqual(stats.updatedArticlesCount, 0)
	}

	func testAllCandidatesFailReportsOneError() async throws {
		let account = TestAccountManager.shared.createAccount(type: .onMyMac)
		accounts.append(account)
		let feedURL = "https://rsshub.app/huggingface/daily-papers"
		let feed = account.createFeed(with: nil, url: feedURL, feedID: feedURL, homePageURL: nil)
		let url = try XCTUnwrap(URL(string: feedURL))

		let retrier = RSSHubFallbackRetrier(loader: FailingLoader(), instances: [
			try XCTUnwrap(RSSHubInstance("https://rsshub.app")),
			try XCTUnwrap(RSSHubInstance("https://first.example")),
			try XCTUnwrap(RSSHubInstance("https://second.example"))
		])
		let refresher = LocalAccountRefresher(rssHubRetrier: retrier)

		refresher.handleHTTPError(feed: feed, url: url, statusCode: 403, generation: refresher.currentRefreshGeneration)

		var spins = 0
		while refresher.refreshStatsSnapshot.pendingRSSHubRetries > 0 && spins < 1000 {
			await Task.yield()
			spins += 1
		}

		XCTAssertEqual(refresher.refreshStatsSnapshot.feedsErrored, 1)
		XCTAssertEqual(refresher.refreshStatsSnapshot.pendingRSSHubRetries, 0)
	}

	func testCancelledErrorDoesNotStartRetry() throws {
		let account = TestAccountManager.shared.createAccount(type: .onMyMac)
		accounts.append(account)
		let feedURL = "https://rsshub.app/huggingface/daily-papers"
		let feed = account.createFeed(with: nil, url: feedURL, feedID: feedURL, homePageURL: nil)
		let url = try XCTUnwrap(URL(string: feedURL))
		let refresher = LocalAccountRefresher()

		let cancelledError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
		let started = refresher.attemptRSSHubRetry(feed: feed,
												   url: url,
												   generation: refresher.currentRefreshGeneration,
												   triggerError: cancelledError)

		XCTAssertFalse(started)
		XCTAssertEqual(refresher.refreshStatsSnapshot.pendingRSSHubRetries, 0)
	}

	func testSuspendedRefresherDoesNotStartRetry() throws {
		let account = TestAccountManager.shared.createAccount(type: .onMyMac)
		accounts.append(account)
		let feedURL = "https://rsshub.app/huggingface/daily-papers"
		let feed = account.createFeed(with: nil, url: feedURL, feedID: feedURL, homePageURL: nil)
		let url = try XCTUnwrap(URL(string: feedURL))
		let retrier = RSSHubFallbackRetrier(loader: NoopLoader(), instances: [try XCTUnwrap(RSSHubInstance("https://rsshub.app"))])
		let refresher = LocalAccountRefresher(rssHubRetrier: retrier)

		refresher.suspend()
		let started = refresher.attemptRSSHubRetry(feed: feed,
												   url: url,
												   generation: refresher.currentRefreshGeneration,
												   triggerError: nil)

		XCTAssertFalse(started)
		XCTAssertEqual(refresher.refreshStatsSnapshot.pendingRSSHubRetries, 0)
	}
}

// MARK: - Helpers

private let minimalRSS = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>Test</title><link>https://example.com</link><description>Test</description><item><title>Item</title><link>https://example.com/1</link><guid>https://example.com/1</guid></item></channel></rss>
"""

private struct NoopLoader: RSSHubFallbackLoading {

	func load(_ url: URL) async throws -> RSSHubFallbackResponse {
		RSSHubFallbackResponse(data: Data("<rss/>".utf8), statusCode: 200, url: url)
	}
}

private struct FailingLoader: RSSHubFallbackLoading {

	func load(_ url: URL) async throws -> RSSHubFallbackResponse {
		throw URLError(.cannotConnectToHost)
	}
}

private struct MockLoader: RSSHubFallbackLoading {

	let handler: @Sendable (URL) async throws -> RSSHubFallbackResponse

	func load(_ url: URL) async throws -> RSSHubFallbackResponse {
		try await handler(url)
	}
}

private actor URLRecorder {

	private(set) var urls = [URL]()

	func record(_ url: URL) {
		urls.append(url)
	}
}
