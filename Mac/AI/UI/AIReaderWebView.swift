//
//  AIReaderWebView.swift
//  NetNewsWire
//

import AppKit
import WebKit

/// Selects the document URL for the AI reading panes.
///
/// `loadHTMLString` without a base URL leaves the document with a null origin.
/// YouTube refuses to play embeds from a null origin and shows "Video player
/// configuration error / Error 153", so the panes always load with a real
/// https origin. The article URL is used when it is usable; otherwise a stable
/// site URL stands in. A youtube.com base is not a valid fallback: the embed
/// host rejects it with "This video is unavailable / 152-4".
enum AIReaderWebBaseURL {

	static let fallback: URL = {
		guard let url = URL(string: "https://netnewswire.com/") else {
			fatalError("Invalid AI reader fallback base URL")
		}
		return url
	}()

	static func baseURL(articleURL: URL?, externalURL: URL?) -> URL {
		// Article `url` wins over `externalURL`, matching Article.baseURL and
		// ArticleUtilities.preferredURL, so relative subresources resolve
		// against the same origin as the reader and the AI pipeline.
		for candidate in [articleURL, externalURL] {
			guard let url = candidate, isUsable(url) else {
				continue
			}
			return url
		}
		return fallback
	}

	private static func isUsable(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(),
		      scheme == "http" || scheme == "https",
		      let host = url.host?.lowercased(),
		      !host.isEmpty else {
			return false
		}
		return !isYouTubeHost(host)
	}

	/// A YouTube page as the document URL makes the embed host refuse playback
	/// with "This video is unavailable / 152-4", so those hosts fall through to
	/// the neutral fallback instead.
	private static func isYouTubeHost(_ host: String) -> Bool {
		let blocked = ["youtube.com", "youtu.be", "youtube-nocookie.com"]
		return blocked.contains { host == $0 || host.hasSuffix(".\($0)") }
	}
}

/// The rewrite and translation pages are plain web views, so they do not inherit the
/// article view's keyboard routing. Without it the reading shortcuts, Escape included,
/// stop working while one of those tabs has focus.
final class AIReaderWebView: WKWebView {

	override init(frame: CGRect, configuration: WKWebViewConfiguration) {
		super.init(frame: frame, configuration: configuration)
		navigationDelegate = self
		uiDelegate = self
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		navigationDelegate = self
		uiDelegate = self
	}

	override func keyDown(with event: NSEvent) {
		if MainWindowKeyboardHandler.shared.keydown(event, in: self) {
			return
		}
		super.keyDown(with: event)
	}
}

// MARK: - WKNavigationDelegate & WKUIDelegate

extension AIReaderWebView: WKNavigationDelegate, WKUIDelegate {

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
		// The reading pages offer no way back once they navigate away, so links
		// open in the system browser, matching the article view.
		if navigationAction.navigationType == .linkActivated {
			if let url = navigationAction.request.url {
				openInBrowser(url, flags: navigationAction.modifierFlags)
			}
			decisionHandler(.cancel, preferences)
			return
		}

		decisionHandler(.allow, preferences)
	}

	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		if let url = navigationAction.request.url {
			openInBrowser(url, flags: navigationAction.modifierFlags)
		}

		return nil
	}

	private func openInBrowser(_ url: URL, flags: NSEvent.ModifierFlags) {
		let invert = flags.contains(.shift) || flags.contains(.command)
		Browser.open(url.absoluteString, invertPreference: invert)
	}
}

/// The pane's root view takes focus when the web view is hidden, such as on the
/// empty state, so the reading shortcuts keep working there too.
final class AIReaderContainerView: NSView {

	override var acceptsFirstResponder: Bool {
		return true
	}

	override func keyDown(with event: NSEvent) {
		if MainWindowKeyboardHandler.shared.keydown(event, in: self) {
			return
		}
		super.keyDown(with: event)
	}
}
