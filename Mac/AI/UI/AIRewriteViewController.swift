//
//  AIRewriteViewController.swift
//  NetNewsWire
//

import AppKit
import WebKit
import AI
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
		isPaper ? "论文解读" : "中文改写"
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

	init() {
		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		self.webView = WKWebView(frame: .zero, configuration: configuration)
		super.init(nibName: nil, bundle: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRewriteReady(_:)), name: .aiRewriteReady, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleJobFailed(_:)), name: .aiJobFailed, object: nil)
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

	/// Re-checks the store when the tab is selected and there is nothing to show.
	func refreshIfNeeded() {
		guard case .empty = state else {
			return
		}
		reload()
	}

	func reload() {
		pollTask?.cancel()
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
			emptyLabel.stringValue = "选择一篇文章后可查看中文改写"
			generateButton.isHidden = true
			emptyView.isHidden = false
		case .reading:
			loadingLabel.stringValue = "正在读取改写"
			loadingIndicator.startAnimation(nil)
			loadingView.isHidden = false
		case .empty:
			emptyLabel.stringValue = isPaper ? "这篇论文还没有 AI 解读。" : "这篇文章还没有中文改写。"
			generateButton.title = isPaper ? "生成解读" : "生成"
			generateButton.isHidden = false
			emptyView.isHidden = false
		case .generating:
			loadingLabel.stringValue = isPaper ? "解读任务已提交，完成后会自动刷新" : "改写任务已提交，完成后会自动刷新"
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
		webView.loadHTMLString(AIMarkdownRenderer.document(from: rewrite.bodyMarkdown), baseURL: nil)
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
		return rewrite.contentHash != AIContentHash.titleOrRewrite(for: AIArticle(article: article))
	}
}

// MARK: - Actions

private extension AIRewriteViewController {

	@objc func generateButtonClicked() {
		guard let articleID = article?.articleID else {
			return
		}

		let now = Date()
		let job = AIJob(
			id: "rewrite:\(articleID)",
			articleID: articleID,
			kind: .rewrite,
			priority: 100,
			availableAt: now,
			createdAt: now
		)

		state = .generating
		updateContent()

		Task { @MainActor in
			do {
				try await AIEnvironment.shared.queue.enqueue(job)
				self.startPolling(for: articleID)
			} catch {
				self.state = .error("提交改写任务失败：\(error.localizedDescription)")
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
			let deadline = Date().addingTimeInterval(90)
			while !Task.isCancelled, Date() < deadline {
				try? await Task.sleep(for: .seconds(3))
				guard !Task.isCancelled, let self else {
					return
				}
				guard self.article?.articleID == articleID, case .generating = self.state else {
					return
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
