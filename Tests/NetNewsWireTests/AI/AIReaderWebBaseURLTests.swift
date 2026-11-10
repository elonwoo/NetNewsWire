//
//  AIReaderWebBaseURLTests.swift
//  NetNewsWireTests
//

import AI
import AppKit
import Foundation
import Testing
import WebKit

@testable import NetNewsWire

@Suite @MainActor final class AIReaderWebBaseURLTests {

	@Test func articleURLWinsOverExternalURL() {
		// JSON Feed item: url is the blog post, external_url is a tweet. The
		// reader and the AI pipeline resolve against the blog, so the pane must
		// too, otherwise relative images point at the wrong origin.
		let url = AIReaderWebBaseURL.baseURL(
			articleURL: URL(string: "https://blog.example/posts/1"),
			externalURL: URL(string: "https://twitter.com/x/status/1")
		)

		#expect(url.absoluteString == "https://blog.example/posts/1")
	}

	@Test func fallsBackToExternalURLWhenArticleURLIsMissing() {
		let url = AIReaderWebBaseURL.baseURL(
			articleURL: nil,
			externalURL: URL(string: "https://kottke.org/26/02/a-youtuber-discovered")
		)

		#expect(url.absoluteString == "https://kottke.org/26/02/a-youtuber-discovered")
	}

	@Test func youTubeHostsUseTheHTTPSFallback() {
		let hosts = [
			"https://youtube.com/watch?v=VIDEOTEST01",
			"https://www.youtube.com/watch?v=VIDEOTEST01",
			"https://m.youtube.com/watch?v=VIDEOTEST01",
			"https://music.youtube.com/watch?v=VIDEOTEST01",
			"https://youtu.be/VIDEOTEST01",
			"https://www.youtu.be/VIDEOTEST01",
			"https://youtube-nocookie.com/embed/VIDEOTEST01",
			"https://www.youtube-nocookie.com/embed/VIDEOTEST01"
		]

		for host in hosts {
			let url = AIReaderWebBaseURL.baseURL(articleURL: URL(string: host), externalURL: nil)

			#expect(url == AIReaderWebBaseURL.fallback, Comment(rawValue: host))
		}

		let channel = AIReaderWebBaseURL.baseURL(
			articleURL: URL(string: "https://www.youtube.com/watch?v=VIDEOTEST01"),
			externalURL: URL(string: "https://youtu.be/VIDEOTEST01")
		)
		#expect(channel == AIReaderWebBaseURL.fallback)
	}

	@Test func youTubeArticleURLFallsThroughToExternalURL() async throws {
		// A video share can carry the real blog post as externalURL. The YouTube
		// article URL cannot serve as the document URL, so the pane must take the
		// external page rather than dropping all the way to the neutral fallback.
		let url = AIReaderWebBaseURL.baseURL(
			articleURL: URL(string: "https://www.youtube.com/watch?v=abc123"),
			externalURL: URL(string: "https://example.com/post")
		)

		#expect(url.absoluteString == "https://example.com/post")
		#expect(try await origin(of: url) == "https://example.com")
	}

	@Test func unusableArticleURLsUseTheHTTPSFallback() {
		let samples: [(articleURL: URL?, externalURL: URL?)] = [
			(nil, nil),
			(URL(string: ""), URL(string: "")),
			(URL(string: "javascript:alert(1)"), nil),
			(URL(string: "file:///tmp/article.html"), nil),
			(URL(string: "data:text/html,<p>x</p>"), nil)
		]

		for sample in samples {
			let url = AIReaderWebBaseURL.baseURL(articleURL: sample.articleURL, externalURL: sample.externalURL)

			#expect(url.scheme == "https")
			#expect(url.host == "netnewswire.com")
		}
	}

	@Test func realArticleURLProducesANonNullOrigin() async throws {
		let base = AIReaderWebBaseURL.baseURL(articleURL: URL(string: "https://kottke.org/26/02/post"), externalURL: nil)

		#expect(try await origin(of: base) == "https://kottke.org")
		#expect(try await origin(of: AIReaderWebBaseURL.fallback) == "https://netnewswire.com")
	}

	/// Documents the bug this base URL exists for: without it the document
	/// origin is `null` and YouTube refuses the embed with error 153.
	@Test func nilBaseURLGivesTheNullOriginThatYouTubeRejects() async throws {
		#expect(try await origin(of: nil) == "null")
	}

	@Test func paneRelativeImagesResolveAgainstTheArticleOrigin() async throws {
		let translation = AI.Translation(
			articleID: "article",
			titleZh: "标题",
			summaryZh: nil,
			blocks: [
				AI.TranslationBlock(index: 0, source: "", target: "", targetHTML: #"<p><img src="/images/a.png" alt="A"></p>"#)
			],
			model: "model",
			provider: "provider",
			contentHash: "hash",
			createdAt: Date(),
			updatedAt: Date()
		)
		let html = AITranslationViewController.html(for: translation)
		let base = AIReaderWebBaseURL.baseURL(
			articleURL: URL(string: "https://blog.example/posts/1"),
			externalURL: URL(string: "https://twitter.com/x/status/1")
		)

		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), configuration: configuration)
		webView.loadHTMLString(html, baseURL: base)

		for _ in 0..<50 {
			if let ready = try? await webView.evaluateJavaScript("document.images.length > 0") as? Bool, ready {
				let source = try await webView.evaluateJavaScript("document.images[0].src")
				#expect(source as? String == "https://blog.example/images/a.png")
				return
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		Issue.record("image did not load into the document")
	}

	private func origin(of baseURL: URL?) async throws -> String? {
		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), configuration: configuration)
		webView.loadHTMLString("<!doctype html><html><body><div id=\"probe\"></div></body></html>", baseURL: baseURL)

		for _ in 0..<50 {
			if let ready = try? await webView.evaluateJavaScript("document.getElementById('probe') !== null") as? Bool, ready {
				let value = try await webView.evaluateJavaScript("location.origin")
				return value as? String
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		return nil
	}
}
