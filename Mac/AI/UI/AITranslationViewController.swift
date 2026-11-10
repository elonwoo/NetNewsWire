//
//  AITranslationViewController.swift
//  NetNewsWire
//

import AppKit
import WebKit
import AI
import Account
import Articles

/// The Chinese translation tab of the reading area: empty state, translation
/// progress, and the translated article in Chinese-only mode.
@MainActor
final class AITranslationViewController: NSViewController {

	var article: Article? {
		didSet {
			guard article?.articleID != oldValue?.articleID else {
				return
			}
			reload()
		}
	}

	private enum ContentState {
		case noArticle
		case reading
		case empty(AI.Translation?)
		case noBody(AI.Translation?)
		case translating
		case translation(AI.Translation)
		case error(String)
	}

	private let headerBar = NSView()
	private let contentView = NSView()
	private let emptyView = NSStackView()
	private let emptyTitleLabel = NSTextField(wrappingLabelWithString: "")
	private let emptyLabel = NSTextField(wrappingLabelWithString: "还没有中文译文")
	private let translateButton = NSButton()
	private let loadingView = NSStackView()
	private let loadingIndicator = NSProgressIndicator()
	private let loadingLabel = NSTextField(labelWithString: "正在读取译文")
	private let errorView = NSStackView()
	private let errorLabel = NSTextField(wrappingLabelWithString: "")
	private let retryButton = NSButton()
	private let webView: WKWebView

	private var state: ContentState = .noArticle
	private var isPaneVisible = false
	private var loadToken = UUID()
	private var headerHeightConstraint: NSLayoutConstraint?

	init() {
		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		self.webView = AIReaderWebView(frame: .zero, configuration: configuration)
		super.init(nibName: nil, bundle: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleTranslationReady(_:)), name: .aiTranslationReady, object: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let rootView = AIReaderContainerView()
		view = rootView

		makeHeaderBar()
		makeStateViews()
		makeWebView()

		rootView.addSubview(headerBar)
		rootView.addSubview(contentView)
		headerBar.translatesAutoresizingMaskIntoConstraints = false
		contentView.translatesAutoresizingMaskIntoConstraints = false

		let headerHeightConstraint = headerBar.heightAnchor.constraint(equalToConstant: 36)
		self.headerHeightConstraint = headerHeightConstraint

		NSLayoutConstraint.activate([
			headerBar.topAnchor.constraint(equalTo: rootView.topAnchor),
			headerBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
			headerBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
			headerHeightConstraint,
			contentView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
			contentView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
			contentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
			contentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
		])

		updateContent()
	}

	func focus() {
		guard let window = view.window else {
			return
		}
		// A hidden web view takes focus but never sees key events, which cuts the
		// reading shortcuts off, so fall back to the pane's own view.
		if webView.isHidden || !window.makeFirstResponder(webView) {
			window.makeFirstResponder(view)
		}
	}

	/// Tracks whether the translation tab is the one on screen. The pane is
	/// reloaded whenever the article changes, so the visibility has to survive
	/// across reloads instead of being a one-shot callback.
	func setPaneVisible(_ visible: Bool) {
		isPaneVisible = visible
		enqueueTranslationIfNeeded()
	}

	/// Queues a translation only when the pane is on screen, an article is
	/// showing with no cached translation, its feed still allows translation,
	/// and no job is in flight, so opening the tab never repeats work. The
	/// acceptance gate leaves the tab empty instead of looping on a gated
	/// enqueue.
	func enqueueTranslationIfNeeded() {
		guard !AIJobExecutor.shared.isAutoWorkDisabled,
		      isPaneVisible,
		      case .empty = state,
		      article?.feed?.aiTranslationEnabled != false,
		      let article,
		      AIArticleLanguageGate.allows(article) else {
			return
		}
		translateButtonClicked()
	}

	func reload() {
		guard let articleID = article?.articleID else {
			state = .noArticle
			updateContent()
			return
		}
		let hasBody = article.map { AIArticle(article: $0).hasBody } ?? false

		let token = UUID()
		loadToken = token
		state = .reading
		updateContent()

		Task { @MainActor in
			do {
				let translation = try await AIEnvironment.shared.store.translation(for: articleID)
				guard self.loadToken == token, self.article?.articleID == articleID else {
					return
				}
				if !hasBody {
					self.state = .noBody(translation)
				} else if let translation, !translation.blocks.isEmpty {
					self.state = .translation(translation)
				} else {
					self.state = .empty(translation)
				}
				self.updateContent()
				self.enqueueTranslationIfNeeded()
			} catch {
				guard self.loadToken == token else {
					return
				}
				self.state = .error("读取译文失败：\(error.localizedDescription)")
				self.updateContent()
			}
		}
	}
}

// MARK: - View construction

private extension AITranslationViewController {

	func makeHeaderBar() {
		headerBar.wantsLayer = true
		headerBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		headerBar.addSubview(separator)

		NSLayoutConstraint.activate([
			separator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor)
		])
	}

	func makeStateViews() {
		emptyTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
		emptyTitleLabel.textColor = .labelColor
		emptyTitleLabel.alignment = .center

		emptyLabel.font = .systemFont(ofSize: 13)
		emptyLabel.textColor = .secondaryLabelColor
		emptyLabel.alignment = .center

		translateButton.title = "翻译"
		translateButton.bezelStyle = .rounded
		translateButton.target = self
		translateButton.action = #selector(translateButtonClicked)

		emptyView.orientation = .vertical
		emptyView.alignment = .centerX
		emptyView.spacing = 12
		emptyView.addArrangedSubview(emptyTitleLabel)
		emptyView.addArrangedSubview(emptyLabel)
		emptyView.addArrangedSubview(translateButton)

		loadingIndicator.style = .spinning
		loadingIndicator.controlSize = .small
		loadingLabel.font = .systemFont(ofSize: 12)
		loadingLabel.textColor = .secondaryLabelColor
		loadingView.orientation = .vertical
		loadingView.alignment = .centerX
		loadingView.spacing = 10
		loadingView.addArrangedSubview(loadingIndicator)
		loadingView.addArrangedSubview(loadingLabel)

		errorLabel.font = .systemFont(ofSize: 12)
		errorLabel.textColor = .systemRed
		errorLabel.alignment = .center
		errorLabel.maximumNumberOfLines = 4
		retryButton.title = "重试"
		retryButton.bezelStyle = .rounded
		retryButton.target = self
		retryButton.action = #selector(retryButtonClicked)
		errorView.orientation = .vertical
		errorView.alignment = .centerX
		errorView.spacing = 10
		errorView.addArrangedSubview(errorLabel)
		errorView.addArrangedSubview(retryButton)

		for stateView in [emptyView, loadingView, errorView] {
			stateView.translatesAutoresizingMaskIntoConstraints = false
			contentView.addSubview(stateView)
			NSLayoutConstraint.activate([
				stateView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
				stateView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
				stateView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
				stateView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20)
			])
			stateView.isHidden = true
		}
	}

	func makeWebView() {
		webView.translatesAutoresizingMaskIntoConstraints = false
		webView.underPageBackgroundColor = .textBackgroundColor
		contentView.addSubview(webView)
		NSLayoutConstraint.activate([
			webView.topAnchor.constraint(equalTo: contentView.topAnchor),
			webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
		])
		webView.isHidden = true
	}

	func updateContent() {
		loadingIndicator.stopAnimation(nil)
		emptyView.isHidden = true
		loadingView.isHidden = true
		errorView.isHidden = true
		webView.isHidden = true
		headerBar.isHidden = true
		emptyTitleLabel.isHidden = true

		switch state {
		case .noArticle:
			emptyLabel.stringValue = "选择一篇文章后可查看中文译文"
			translateButton.isHidden = true
			emptyView.isHidden = false
		case .reading:
			loadingLabel.stringValue = "正在读取译文"
			loadingIndicator.startAnimation(nil)
			loadingView.isHidden = false
		case .empty(let translation):
			let titleZh = translation?.titleZh?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			if titleZh.isEmpty {
				emptyLabel.stringValue = "还没有中文译文"
			} else {
				emptyTitleLabel.stringValue = titleZh
				emptyTitleLabel.isHidden = false
				emptyLabel.stringValue = "标题已翻译，正文未翻译"
			}
			translateButton.isHidden = false
			emptyView.isHidden = false
		case .noBody(let translation):
			if let translation {
				headerBar.isHidden = false
				webView.isHidden = false
				render(translation)
			} else {
				emptyLabel.stringValue = "这篇文章没有正文"
				translateButton.isHidden = true
				emptyView.isHidden = false
			}
		case .translating:
			loadingLabel.stringValue = "翻译任务已提交，完成后会自动刷新"
			loadingIndicator.startAnimation(nil)
			loadingView.isHidden = false
		case .translation(let translation):
			headerBar.isHidden = false
			webView.isHidden = false
			render(translation)
		case .error(let message):
			errorLabel.stringValue = message
			errorView.isHidden = false
		}

		headerHeightConstraint?.constant = headerBar.isHidden ? 0 : 36
	}

	func render(_ translation: AI.Translation) {
		// A null-origin document makes YouTube reject the embed with error 153.
		let baseURL = AIReaderWebBaseURL.baseURL(articleURL: article?.url, externalURL: article?.externalURL)
		webView.loadHTMLString(Self.html(for: translation), baseURL: baseURL)
	}
}

// MARK: - Actions

private extension AITranslationViewController {

	@objc func translateButtonClicked() {
		guard let article = article else {
			return
		}
		let aiArticle = AIArticle(article: article)

		state = .translating
		updateContent()

		Task { @MainActor in
			let result = await AIJobExecutor.shared.enqueueBodyTranslation(for: aiArticle)
			switch result {
			case .enqueued, .alreadyInFlight:
				self.state = .translating
				self.updateContent()
			case .notNeeded:
				self.reload()
			case .failed:
				self.state = .error("提交翻译任务失败")
				self.updateContent()
			}
		}
	}

	@objc func retryButtonClicked() {
		reload()
	}

	@objc nonisolated func handleTranslationReady(_ note: Notification) {
		let articleID = note.userInfo?[AIUserInfoKey.articleID] as? String
		Task { @MainActor in
			guard let articleID, articleID == self.article?.articleID else {
				return
			}
			self.reload()
		}
	}
}

// MARK: - HTML

extension AITranslationViewController {

	static func html(for translation: AI.Translation) -> String {
		let title = translation.titleZh.map(escapeHTML) ?? ""
		let summary = translation.summaryZh.map(escapeHTML) ?? ""

		var blocks = ""
		for block in translation.blocks {
			let target: String
			if let targetHTML = block.targetHTML, !targetHTML.isEmpty {
				// Rows written before the sanitizer learned to drop self-closing
				// script tags can still hold active content, so stored HTML is
				// cleaned again here instead of being trusted.
				target = HTMLSourceBlocks.sanitizedHTML(targetHTML)
			} else {
				let escapedTarget = escapeHTML(block.target).replacingOccurrences(of: "\n", with: "<br>")
				target = "<p>\(HTMLSourceBlocks.sanitizedHTML(escapedTarget))</p>"
			}

			blocks += """
			<section class="block chinese-only">
				<div class="target">\(target)</div>
			</section>
			"""
		}

		if blocks.isEmpty {
			blocks = "<p class=\"empty\">正文译文为空。</p>"
		}

		let titleHTML = title.isEmpty ? "" : "<h1>\(title)</h1>"
		let summaryHTML = summary.isEmpty ? "" : "<p class=\"summary\">\(summary)</p>"

		// Rewrite only the body: YouTube links become playable embeds, while the
		// document head and CSS above stay untouched.
		let bodyHTML = YouTubeEmbedRewriter.rewriteHTML(
			[titleHTML, summaryHTML, blocks].joined(separator: "\n")
		)

		return """
		<!doctype html>
		<html>
		<head>
		<meta charset="utf-8">
		<style>
		:root {
			color-scheme: light dark;
			--bg: #ffffff;
			--fg: #1d1d1f;
			--muted: #6e6e73;
			--line: #e5e5e7;
			--accent: #0a84ff;
		}
		@media (prefers-color-scheme: dark) {
			:root {
				--bg: #1e1e1e;
				--fg: #e8e8e8;
				--muted: #a1a1a6;
				--line: #3a3a3c;
				--accent: #4da3ff;
			}
		}
		* { box-sizing: border-box; }
		html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
		body { font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; font-size: 15px; line-height: 1.75; padding: 20px 24px 48px; }
		h1 { font-size: 21px; line-height: 1.4; margin: 0 0 10px; }
		.summary { color: var(--muted); font-size: 14px; margin-bottom: 20px; }
		.block { padding: 14px 0; }
		.target { min-width: 0; }
		.target p:first-child { margin-top: 0; }
		.target p:last-child { margin-bottom: 0; }
		a { color: var(--accent); }
		img { max-width: 100%; height: auto; }
		blockquote { margin: 12px 0; padding-left: 14px; border-left: 3px solid var(--line); color: var(--muted); }
		pre, code { font-family: "SF Mono", Menlo, monospace; font-size: 13px; }
		pre { overflow-x: auto; padding: 10px; background: rgba(127, 127, 127, 0.12); border-radius: 6px; }
		.empty { color: var(--muted); }
		</style>
		</head>
		<body>
		\(bodyHTML)
		</body>
		</html>
		"""
	}

	private static func escapeHTML(_ string: String) -> String {
		string
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}
}
