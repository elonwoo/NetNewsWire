//
//  AIRewriteViewController.swift
//  NetNewsWire
//

import AppKit
import WebKit
import AI
import Account
import Articles

/// The Chinese rewrite tab of the reading area: empty state, generation
/// progress, and the rendered rewrite for the selected article.
@MainActor
final class AIRewriteViewController: NSViewController {

	var article: Article? {
		didSet {
			guard article?.articleID != oldValue?.articleID else {
				return
			}
			reload()
		}
	}

	/// The tab label changes for paper articles.
	var tabTitle: String {
		isPaper ? "论文解读" : "改写"
	}

	static func isStale(rewrite: AI.Rewrite, article: AIArticle) -> Bool {
		switch AIContentHash.rewriteState(stored: rewrite.contentHash, article: article) {
		case .pipelineOutdated, .contentChanged:
			return true
		case .missing, .current:
			return false
		}
	}

	/// A removed rewrite refreshes the pane only when it is already showing that
	/// article's rewrite. It must never pull the reader onto another tab.
	static func shouldRefreshAfterRewriteRemoval(eventArticleID: String?, paneArticleID: String?, isShowingRewrite: Bool) -> Bool {
		guard isShowingRewrite, let eventArticleID, let paneArticleID else {
			return false
		}
		return eventArticleID == paneArticleID
	}

	private enum ContentState {
		case noArticle
		case reading
		case empty
		case generating
		case rewrite(AI.Rewrite)
		case error(String)
	}

	private let headerBar = NSView()
	private let actionButton = NSButton()
	private let contentView = NSView()
	private let emptyView = NSStackView()
	private let emptyLabel = NSTextField(wrappingLabelWithString: "")
	private let generateButton = NSButton()
	private let loadingView = NSStackView()
	private let loadingIndicator = NSProgressIndicator()
	private let loadingLabel = NSTextField(labelWithString: "正在读取改写")
	private let errorView = NSStackView()
	private let errorLabel = NSTextField(wrappingLabelWithString: "")
	private let retryButton = NSButton()
	private let webView: WKWebView

	private var state: ContentState = .noArticle
	private var loadToken = UUID()
	private var currentRewrite: AI.Rewrite?
	private var headerHeightConstraint: NSLayoutConstraint?
	private var pollTask: Task<Void, Never>?
	/// True once generation has run longer than the quick-feedback window.
	private var isSlowGeneration = false

	init() {
		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		self.webView = AIReaderWebView(frame: .zero, configuration: configuration)
		super.init(nibName: nil, bundle: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRewriteReady(_:)), name: .aiRewriteReady, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRewriteReady(_:)), name: .aiRewriteStored, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRewriteRemoved(_:)), name: .aiRewriteRemoved, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleJobFailed(_:)), name: .aiJobFailed, object: nil)
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

	/// Re-checks the store when the tab is selected and there is nothing to show.
	func refreshIfNeeded() {
		guard case .empty = state else {
			return
		}
		reload()
	}

	func reload() {
		pollTask?.cancel()
		isSlowGeneration = false
		guard let articleID = article?.articleID else {
			currentRewrite = nil
			state = .noArticle
			updateContent()
			return
		}

		let token = UUID()
		loadToken = token
		currentRewrite = nil
		state = .reading
		updateContent()

		Task { @MainActor in
			do {
				let rewrite = try await AIEnvironment.shared.store.rewrite(for: articleID)
				guard self.loadToken == token, self.article?.articleID == articleID else {
					return
				}
				if let rewrite {
					self.currentRewrite = rewrite
					self.state = .rewrite(rewrite)
				} else {
					self.state = .empty
				}
				self.updateContent()
			} catch {
				guard self.loadToken == token else {
					return
				}
				self.state = .error("读取改写失败：\(error.localizedDescription)")
				self.updateContent()
			}
		}
	}
}

// MARK: - View construction

private extension AIRewriteViewController {

	func makeHeaderBar() {
		headerBar.wantsLayer = true
		headerBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

		actionButton.translatesAutoresizingMaskIntoConstraints = false
		actionButton.title = "重写"
		actionButton.bezelStyle = .rounded
		actionButton.controlSize = .small
		actionButton.target = self
		actionButton.action = #selector(generateButtonClicked)
		headerBar.addSubview(actionButton)

		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		headerBar.addSubview(separator)

		NSLayoutConstraint.activate([
			actionButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
			actionButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
			separator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor)
		])
	}

	func makeStateViews() {
		emptyLabel.font = .systemFont(ofSize: 13)
		emptyLabel.textColor = .secondaryLabelColor
		emptyLabel.alignment = .center

		generateButton.title = "生成"
		generateButton.bezelStyle = .rounded
		generateButton.target = self
		generateButton.action = #selector(generateButtonClicked)

		emptyView.orientation = .vertical
		emptyView.alignment = .centerX
		emptyView.spacing = 12
		emptyView.addArrangedSubview(emptyLabel)
		emptyView.addArrangedSubview(generateButton)

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
			emptyLabel.stringValue = "选择一篇文章后可查看改写"
			generateButton.isHidden = true
			emptyView.isHidden = false
		case .reading:
			loadingLabel.stringValue = "正在读取改写"
			loadingIndicator.startAnimation(nil)
			loadingView.isHidden = false
		case .empty:
			emptyLabel.stringValue = isPaper ? "这篇论文还没有 AI 解读。" : "这篇文章还没有改写。"
			generateButton.title = isPaper ? "生成解读" : "生成"
			generateButton.isHidden = false
			emptyView.isHidden = false
		case .generating:
			if isSlowGeneration {
				loadingLabel.stringValue = "仍在生成，可离开此页"
			} else {
				loadingLabel.stringValue = isPaper ? "解读任务已提交，完成后会自动刷新" : "改写任务已提交，完成后会自动刷新"
			}
			loadingIndicator.startAnimation(nil)
			loadingView.isHidden = false
		case .rewrite(let rewrite):
			headerBar.isHidden = false
			webView.isHidden = false
			actionButton.title = isStale(rewrite) ? "更新" : "重写"
			render(rewrite)
		case .error(let message):
			errorLabel.stringValue = message
			errorView.isHidden = false
		}

		headerHeightConstraint?.constant = headerBar.isHidden ? 0 : 36
	}

	func render(_ rewrite: AI.Rewrite) {
		// A null-origin document makes YouTube reject the embed with error 153.
		let baseURL = AIReaderWebBaseURL.baseURL(articleURL: article?.url, externalURL: article?.externalURL)
		webView.loadHTMLString(AIMarkdownRenderer.document(from: rewrite.bodyMarkdown), baseURL: baseURL)
	}

	var isPaper: Bool {
		guard let article else {
			return false
		}
		return AIRewriteKindSelector.kind(for: AIArticle(article: article)) == .paper
	}

	func isStale(_ rewrite: AI.Rewrite) -> Bool {
		guard let article else {
			return false
		}
		return Self.isStale(rewrite: rewrite, article: AIArticle(article: article))
	}
}

// MARK: - Actions

private extension AIRewriteViewController {

	@objc func generateButtonClicked() {
		guard let article = article else {
			return
		}
		// A feed with rewrite turned off has no rewrite UI, but keep the entry
		// point locked down in case it is triggered some other way. Chinese
		// articles stay locked unless the feed's language override is set.
		guard article.feed?.aiRewriteEnabled != false, AIArticleLanguageGate.allows(article) else {
			return
		}
		let articleID = article.articleID
		let aiArticle = AIArticle(article: article)

		state = .generating
		isSlowGeneration = false
		updateContent()

		Task { @MainActor in
			let result = await AIJobExecutor.shared.enqueueRewrite(for: aiArticle, origin: .manual)
			switch result {
			case .enqueued, .alreadyInFlight:
				self.startPolling(for: articleID)
			case .alreadyUpToDate, .blocked:
				self.reload()
			case .failed:
				self.state = .error("提交改写任务失败")
				self.updateContent()
			}
		}
	}

	/// The queue does not expose job status, so wait for the stored rewrite
	/// instead of a status transition. Notifications still win the race when
	/// they arrive first.
	func startPolling(for articleID: String) {
		pollTask?.cancel()
		pollTask = Task { @MainActor [weak self] in
			let startedAt = Date()
			let slowThreshold = startedAt.addingTimeInterval(90)
			let deadline = startedAt.addingTimeInterval(10 * 60)
			while !Task.isCancelled, Date() < deadline {
				try? await Task.sleep(for: .seconds(3))
				guard !Task.isCancelled, let self else {
					return
				}
				guard self.article?.articleID == articleID, case .generating = self.state else {
					return
				}
				if !self.isSlowGeneration, Date() >= slowThreshold {
					self.isSlowGeneration = true
					self.updateContent()
				}
				guard let rewrite = try? await AIEnvironment.shared.store.rewrite(for: articleID) else {
					continue
				}
				guard self.article?.articleID == articleID, case .generating = self.state else {
					return
				}
				self.currentRewrite = rewrite
				self.state = .rewrite(rewrite)
				self.updateContent()
				return
			}
			guard !Task.isCancelled, let self, self.article?.articleID == articleID, case .generating = self.state else {
				return
			}
			self.state = .error("改写任务超时，请稍后重试。")
			self.updateContent()
		}
	}

	@objc func retryButtonClicked() {
		reload()
	}

	@objc nonisolated func handleRewriteReady(_ note: Notification) {
		let articleID = note.userInfo?[AIUserInfoKey.articleID] as? String
		Task { @MainActor in
			guard let articleID, articleID == self.article?.articleID else {
				return
			}
			self.reload()
		}
	}

	@objc nonisolated func handleRewriteRemoved(_ note: Notification) {
		let articleID = note.userInfo?[AIUserInfoKey.articleID] as? String
		Task { @MainActor in
			let isShowingRewrite: Bool
			if case .rewrite = self.state {
				isShowingRewrite = true
			} else {
				isShowingRewrite = false
			}
			guard Self.shouldRefreshAfterRewriteRemoval(
				eventArticleID: articleID,
				paneArticleID: self.article?.articleID,
				isShowingRewrite: isShowingRewrite
			) else {
				return
			}
			self.reload()
		}
	}

	@objc nonisolated func handleJobFailed(_ note: Notification) {
		let articleID = note.userInfo?[AIUserInfoKey.articleID] as? String
		let message = note.userInfo?[AIUserInfoKey.error] as? String
		Task { @MainActor in
			guard let articleID, articleID == self.article?.articleID else {
				return
			}
			guard self.canShowJobFailure else {
				return
			}
			self.pollTask?.cancel()
			self.state = .error("任务失败：\(message ?? "未知错误")")
			self.updateContent()
		}
	}
}

private extension AIRewriteViewController {

	/// Only surface a failure when the pane is waiting on a job or has nothing
	/// to show, so a background failure never replaces rendered content.
	var canShowJobFailure: Bool {
		switch state {
		case .generating, .empty:
			return true
		default:
			return false
		}
	}
}
