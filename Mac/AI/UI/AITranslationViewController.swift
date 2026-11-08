//
//  AITranslationViewController.swift
//  NetNewsWire
//

import AppKit
import WebKit
import AI
import Articles

/// The Chinese translation tab of the reading area: empty state, translation
/// progress, and the translated article in either bilingual or Chinese-only mode.
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

	private enum ViewMode: Int {
		case bilingual = 0
		case chineseOnly = 1
	}

	private enum ContentState {
		case noArticle
		case reading
		case empty
		case translating
		case translation(AI.Translation)
		case error(String)
	}

	private static let modeDefaultsKey = "aiTranslationViewMode"

	private let headerBar = NSView()
	private let modeControl = NSSegmentedControl(labels: ["对照", "纯中文"], trackingMode: .selectOne, target: nil, action: nil)
	private let contentView = NSView()
	private let emptyView = NSStackView()
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
	private var loadToken = UUID()
	private var currentTranslation: AI.Translation?
	private var mode: ViewMode
	private var headerHeightConstraint: NSLayoutConstraint?

	init() {
		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		self.webView = WKWebView(frame: .zero, configuration: configuration)
		self.mode = ViewMode(rawValue: UserDefaults.standard.integer(forKey: Self.modeDefaultsKey)) ?? .bilingual
		super.init(nibName: nil, bundle: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleTranslationReady(_:)), name: .aiTranslationReady, object: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let rootView = NSView()
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
		view.window?.makeFirstResponder(webView)
	}

	func reload() {
		guard let articleID = article?.articleID else {
			currentTranslation = nil
			state = .noArticle
			updateContent()
			return
		}

		let token = UUID()
		loadToken = token
		currentTranslation = nil
		state = .reading
		updateContent()

		Task { @MainActor in
			do {
				let translation = try await AIEnvironment.shared.store.translation(for: articleID)
				guard self.loadToken == token, self.article?.articleID == articleID else {
					return
				}
				if let translation {
					self.currentTranslation = translation
					self.state = .translation(translation)
				} else {
					self.state = .empty
				}
				self.updateContent()
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

		modeControl.translatesAutoresizingMaskIntoConstraints = false
		modeControl.selectedSegment = mode.rawValue
		modeControl.controlSize = .small
		modeControl.segmentStyle = .rounded
		modeControl.target = self
		modeControl.action = #selector(modeChanged(_:))
		headerBar.addSubview(modeControl)

		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		headerBar.addSubview(separator)

		NSLayoutConstraint.activate([
			modeControl.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
			modeControl.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
			separator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor)
		])
	}

	func makeStateViews() {
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

		switch state {
		case .noArticle:
			emptyLabel.stringValue = "选择一篇文章后可查看中文译文"
			translateButton.isHidden = true
			emptyView.isHidden = false
		case .reading:
			loadingLabel.stringValue = "正在读取译文"
			loadingIndicator.startAnimation(nil)
			loadingView.isHidden = false
		case .empty:
			emptyLabel.stringValue = "还没有中文译文"
			translateButton.isHidden = false
			emptyView.isHidden = false
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
		modeControl.selectedSegment = mode.rawValue
		webView.loadHTMLString(Self.html(for: translation, mode: mode), baseURL: nil)
	}
}

// MARK: - Actions

private extension AITranslationViewController {

	@objc func translateButtonClicked() {
		guard let articleID = article?.articleID else {
			return
		}

		let now = Date()
		let job = AIJob(
			id: "bodyTranslation:\(articleID)",
			articleID: articleID,
			kind: .bodyTranslation,
			priority: 100,
			availableAt: now,
			createdAt: now
		)

		state = .translating
		updateContent()

		Task { @MainActor in
			do {
				try await AIEnvironment.shared.queue.enqueue(job)
			} catch {
				self.state = .error("提交翻译任务失败：\(error.localizedDescription)")
				self.updateContent()
			}
		}
	}

	@objc func retryButtonClicked() {
		reload()
	}

	@objc func modeChanged(_ sender: NSSegmentedControl) {
		mode = ViewMode(rawValue: sender.selectedSegment) ?? .bilingual
		UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
		if let currentTranslation {
			render(currentTranslation)
		}
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

private extension AITranslationViewController {

	private static func html(for translation: AI.Translation, mode: ViewMode) -> String {
		let title = translation.titleZh.map(escapeHTML) ?? ""
		let summary = translation.summaryZh.map(escapeHTML) ?? ""

		var blocks = ""
		for block in translation.blocks {
			let source = escapeHTML(block.source).replacingOccurrences(of: "\n", with: "<br>")
			let target: String
			if let targetHTML = block.targetHTML, !targetHTML.isEmpty {
				target = targetHTML
			} else {
				let escapedTarget = escapeHTML(block.target).replacingOccurrences(of: "\n", with: "<br>")
				target = "<p>\(escapedTarget)</p>"
			}

			switch mode {
			case .bilingual:
				blocks += """
				<section class="block">
					<div class="source">\(source)</div>
					<div class="target">\(target)</div>
				</section>
				"""
			case .chineseOnly:
				blocks += """
				<section class="block chinese-only">
					<div class="target">\(target)</div>
				</section>
				"""
			}
		}

		if blocks.isEmpty {
			blocks = "<p class=\"empty\">正文译文为空。</p>"
		}

		let titleHTML = title.isEmpty ? "" : "<h1>\(title)</h1>"
		let summaryHTML = summary.isEmpty ? "" : "<p class=\"summary\">\(summary)</p>"

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
		.block { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 24px; padding: 14px 0; border-top: 1px solid var(--line); }
		.block.chinese-only { display: block; }
		.source { color: var(--muted); font-size: 13px; line-height: 1.65; }
		.target { min-width: 0; }
		.target p:first-child { margin-top: 0; }
		.target p:last-child { margin-bottom: 0; }
		a { color: var(--accent); }
		img { max-width: 100%; height: auto; }
		blockquote { margin: 12px 0; padding-left: 14px; border-left: 3px solid var(--line); color: var(--muted); }
		pre, code { font-family: "SF Mono", Menlo, monospace; font-size: 13px; }
		pre { overflow-x: auto; padding: 10px; background: rgba(127, 127, 127, 0.12); border-radius: 6px; }
		.empty { color: var(--muted); }
		@media (max-width: 680px) {
			.block { grid-template-columns: minmax(0, 1fr); gap: 8px; }
			.source { border-left: 3px solid var(--line); padding-left: 10px; }
		}
		</style>
		</head>
		<body>
		\(titleHTML)
		\(summaryHTML)
		\(blocks)
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
