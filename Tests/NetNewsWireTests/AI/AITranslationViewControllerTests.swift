//
//  AITranslationViewControllerTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing
import WebKit

@testable import NetNewsWire

@Suite final class AITranslationViewControllerTests {

	private let now = Date(timeIntervalSince1970: 1_700_000_000)

	@Test @MainActor func sourceYouTubeIframeBecomesNoCookieEmbed() {
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(
				index: 0,
				source: "Video",
				target: "视频",
				targetHTML: #"<p>视频 <iframe src="https://www.youtube.com/embed/VIDEOTEST01" width="560" height="315"></iframe></p>"#
			)
		])
		let html = AITranslationViewController.html(for: translation)

		#expect(html.contains("https://www.youtube-nocookie.com/embed/VIDEOTEST01"))
		#expect(!html.contains("www.youtube.com/embed"))
		#expect(html.contains("width=\"560\""))
		#expect(html.contains("视频"))
	}

	@Test @MainActor func translatedYouTubeLinkBecomesNoCookieEmbed() {
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(
				index: 0,
				source: "Watch https://youtu.be/VIDEOTEST01。",
				target: "观看 https://youtu.be/VIDEOTEST01。视频",
				targetHTML: nil
			)
		])
		let html = AITranslationViewController.html(for: translation)

		#expect(html.contains("https://www.youtube-nocookie.com/embed/VIDEOTEST01"))
		#expect(!html.contains("youtu.be"))
		#expect(html.contains("。视频"))
	}

	@Test @MainActor func wrappedIframeBlocksRenderInPane() {
		let blockHTML = HTMLSourceBlocks.blocks("<blockquote><iframe src=\"https://www.youtube.com/embed/VIDEOTEST01\"></iframe></blockquote>")
			.map(\.html)
			.joined()
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(index: 0, source: "", target: "", targetHTML: blockHTML)
		])
		let html = AITranslationViewController.html(for: translation)

		#expect(html.contains("https://www.youtube-nocookie.com/embed/VIDEOTEST01"))
	}

	@Test @MainActor func translatedDoubleEscapedEntityStillEmbeds() {
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(
				index: 0,
				source: "",
				target: "观看 https://youtu.be/VIDEOTEST01&amp;nbsp;后续",
				targetHTML: nil
			)
		])
		let html = AITranslationViewController.html(for: translation)

		#expect(html.contains("src=\"https://www.youtube-nocookie.com/embed/VIDEOTEST01\""))
		#expect(html.contains("后续"))
	}

	@Test @MainActor func translatedDeepEscapedEntityStillEmbeds() {
		for suffix in ["&amp;amp;amp;nbsp;", "&amp;amp;amp;amp;nbsp;"] {
			let translation = makeTranslation(blocks: [
				AI.TranslationBlock(
					index: 0,
					source: "",
					target: "观看 https://youtu.be/VIDEOTEST01\(suffix)后续",
					targetHTML: nil
				)
			])
			let html = AITranslationViewController.html(for: translation)

			#expect(html.contains("src=\"https://www.youtube-nocookie.com/embed/VIDEOTEST01\""), Comment(rawValue: suffix))
			#expect(html.contains("后续"), Comment(rawValue: suffix))
		}
	}

	@Test @MainActor func figureIframeBlockRendersInPane() {
		let blockHTML = HTMLSourceBlocks.blocks("<figure><iframe src=\"https://www.youtube.com/embed/VIDEOTEST01\"></iframe><figcaption>Video</figcaption></figure>")
			.map(\.html)
			.joined()
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(index: 0, source: "", target: "", targetHTML: blockHTML)
		])
		let html = AITranslationViewController.html(for: translation)

		#expect(html.contains("youtube-nocookie.com/embed/VIDEOTEST01"))
	}

	@Test @MainActor func duplicateIframesInStoredTargetHTMLRenderOnce() {
		let targetHTML = #"<p>Before</p><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe><p>After</p>"#
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(index: 0, source: "", target: "", targetHTML: targetHTML)
		])
		let html = AITranslationViewController.html(for: translation)

		#expect(html.components(separatedBy: "<iframe").count - 1 == 1)
		#expect(!html.lowercased().contains("www.youtube.com/embed"))
		#expect(html.contains("Before"))
		#expect(html.contains("After"))
	}

	@Test @MainActor func storedTargetHTMLIsSanitizedAtRenderTime() {
		let targetHTML = #"<p onerror="window.__pwned=1">Hello <a href="javascript:alert(1)">link</a><script>window.__pwned=1</script></p><pre><script>window.__pwned=1</script></pre><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe>"#
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(index: 0, source: "", target: "", targetHTML: targetHTML)
		])
		let html = AITranslationViewController.html(for: translation)

		#expect(!html.lowercased().contains("<script"))
		#expect(!html.lowercased().contains("onerror"))
		#expect(!html.lowercased().contains("javascript:"))
		#expect(!html.contains("window.__pwned"))
		#expect(html.contains("<pre></pre>"))
		#expect(html.contains("Hello"))
		#expect(html.contains("link"))
		#expect(html.contains("src=\"https://www.youtube-nocookie.com/embed/VIDEOTEST01\""))
	}

	@Test @MainActor func storedTargetHTMLDoesNotExecuteInWebView() async throws {
		let targetHTML = #"<p onerror="window.__pwned=1">Hello<script>window.__pwned=1</script></p><pre><script>window.__pwned=1</script></pre><iframe src="https://www.youtube.com/embed/VIDEOTEST01"></iframe>"#
		let translation = makeTranslation(blocks: [
			AI.TranslationBlock(index: 0, source: "", target: "", targetHTML: targetHTML)
		])
		let document = AITranslationViewController.html(for: translation)

		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
		webView.loadHTMLString(document, baseURL: AIReaderWebBaseURL.fallback)

		var isLoaded = false
		for _ in 0..<50 {
			if let ready = try? await webView.evaluateJavaScript("document.querySelector('.chinese-only') !== null") as? Bool, ready {
				isLoaded = true
				break
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		#expect(isLoaded)

		let pwned = try await webView.evaluateJavaScript("typeof window.__pwned")
		#expect(pwned as? String == "undefined")
		let scriptCount = try await webView.evaluateJavaScript("document.querySelectorAll('script').length")
		#expect(scriptCount as? Int == 0)
		let embedCount = try await webView.evaluateJavaScript("document.querySelectorAll('iframe[src*=\"youtube-nocookie\"]').length")
		#expect(embedCount as? Int == 1)
	}

	@Test @MainActor func sanitizedScriptProbeDoesNotExecuteInWebView() async throws {
		let probe = #"<pre><script/>window.__pwned=1;//<a title="</script>">x</a></pre>"#
		let sanitized = HTMLSourceBlocks.blocks(probe).map(\.html).joined()
		#expect(sanitized == "<pre></pre>")

		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
		let document = """
		<!doctype html><html><body><section class="block chinese-only"><div class="target" id="probe">\(sanitized)</div></section></body></html>
		"""
		webView.loadHTMLString(document, baseURL: AIReaderWebBaseURL.fallback)

		var isLoaded = false
		for _ in 0..<50 {
			if let ready = try? await webView.evaluateJavaScript("document.getElementById('probe') !== null") as? Bool, ready {
				isLoaded = true
				break
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		#expect(isLoaded)

		let value = try await webView.evaluateJavaScript("typeof window.__pwned")
		#expect(value as? String == "undefined")

		// Positive control: the same harness does execute scripts, so the
		// undefined result above comes from the sanitized output, not from
		// JavaScript being disabled.
		let controlConfiguration = WKWebViewConfiguration()
		controlConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
		let control = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: controlConfiguration)
		control.loadHTMLString(#"<!doctype html><html><body><script>window.__control=1</script><div id="control-probe"></div></body></html>"#, baseURL: nil)

		var controlLoaded = false
		for _ in 0..<50 {
			if let ready = try? await control.evaluateJavaScript("document.getElementById('control-probe') !== null") as? Bool, ready {
				controlLoaded = true
				break
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		#expect(controlLoaded)
		let controlValue = try await control.evaluateJavaScript("typeof window.__control")
		#expect(controlValue as? String == "number")
	}

	private func makeTranslation(blocks: [AI.TranslationBlock]) -> AI.Translation {
		AI.Translation(
			articleID: "article",
			titleZh: "标题",
			summaryZh: "摘要",
			blocks: blocks,
			model: "model",
			provider: "provider",
			contentHash: "hash",
			createdAt: now,
			updatedAt: now
		)
	}
}
