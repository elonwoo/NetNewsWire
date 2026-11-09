//
//  AIDetailPaneViewController.swift
//  NetNewsWire
//

import AI
import Account
import AppKit
import Articles

/// The reading area: a three-tab header (改写 / 原文 / 翻译) above the Chinese
/// rewrite view, the existing article view and the Chinese translation view.
@MainActor
final class AIDetailPaneViewController: NSViewController {

	let detailViewController: DetailViewController
	let rewriteViewController: AIRewriteViewController
	let translationViewController: AITranslationViewController

	var article: Article? {
		didSet {
			if article?.articleID == oldValue?.articleID {
				// The body can arrive after the timeline row, and Chinese
				// detection depends on it. Re-evaluate the language-driven tabs
				// without changing the reader's chosen tab.
				updateTabTitles()
				if !visibleTabs.contains(selectedTab) {
					fallbackFromHiddenTab()
				}
				return
			}
			rewriteViewController.article = article
			translationViewController.article = article
			updateTabTitles()
			updateDefaultTab()
		}
	}

	/// False for a Chinese article whose feed lacks the language override. Such
	/// an article shows only the original tab, even when a rewrite is cached.
	private var articleAllowsAI: Bool {
		guard let article else {
			return true
		}
		return AIArticleLanguageGate.allows(article)
	}

	/// The tabs the current article actually offers, from the feed's two
	/// independent AI switches and the article-level language rule.
	private var visibleTabs: [AIPaneTab] {
		AIPaneTabPolicy.visibleTabs(
			rewriteEnabled: article?.feed?.aiRewriteEnabled ?? true,
			translationEnabled: article?.feed?.aiTranslationEnabled ?? true,
			articleAllowsAI: articleAllowsAI
		)
	}

	private let tabBar = NSView()
	private let tabControl: NSSegmentedControl
	private let contentView = NSView()
	private var selectedTab: AIPaneTab
	private var defaultTabToken: UUID?

	init(detailViewController: DetailViewController, rewriteViewController: AIRewriteViewController = AIRewriteViewController(), translationViewController: AITranslationViewController = AITranslationViewController()) {
		self.detailViewController = detailViewController
		self.rewriteViewController = rewriteViewController
		self.translationViewController = translationViewController
		self.tabControl = NSSegmentedControl(labels: ["改写", "原文", "翻译"], trackingMode: .selectOne, target: nil, action: nil)
		self.selectedTab = .original
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let rootView = NSView()
		view = rootView

		tabBar.translatesAutoresizingMaskIntoConstraints = false
		contentView.translatesAutoresizingMaskIntoConstraints = false
		rootView.addSubview(tabBar)
		rootView.addSubview(contentView)

		tabControl.translatesAutoresizingMaskIntoConstraints = false
		tabControl.controlSize = .small
		tabControl.segmentStyle = .rounded
		tabControl.target = self
		tabControl.action = #selector(tabChanged(_:))
		tabBar.addSubview(tabControl)

		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		tabBar.addSubview(separator)

		NSLayoutConstraint.activate([
			tabBar.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),
			tabBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
			tabBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
			tabBar.heightAnchor.constraint(equalToConstant: 34),
			tabControl.centerXAnchor.constraint(equalTo: tabBar.centerXAnchor),
			tabControl.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
			separator.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
			contentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
			contentView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
			contentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
			contentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
		])

		addChild(detailViewController)
		let detailView = detailViewController.view
		detailView.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(detailView)

		addChild(rewriteViewController)
		let rewriteView = rewriteViewController.view
		rewriteView.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(rewriteView)

		addChild(translationViewController)
		let translationView = translationViewController.view
		translationView.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(translationView)

		for childView in [detailView, rewriteView, translationView] {
			NSLayoutConstraint.activate([
				childView.topAnchor.constraint(equalTo: contentView.topAnchor),
				childView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
				childView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
				childView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
			])
		}

		NotificationCenter.default.addObserver(self, selector: #selector(rewriteDidBecomeReady(_:)), name: .aiRewriteReady, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(translationDidBecomeReady(_:)), name: .aiTranslationReady, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(feedSettingDidChange(_:)), name: .feedSettingDidChange, object: nil)
		updateTabTitles()
		if !visibleTabs.contains(selectedTab) {
			selectedTab = .original
		}
		show(selectedTab)
	}

	func focus() {
		switch selectedTab {
		case .original:
			detailViewController.focus()
		case .rewrite:
			rewriteViewController.focus()
		case .translation:
			translationViewController.focus()
		}
	}
}

private extension AIDetailPaneViewController {

	func updateTabTitles() {
		let tabs = visibleTabs
		if tabControl.segmentCount != tabs.count {
			tabControl.segmentCount = tabs.count
		}
		for (index, tab) in tabs.enumerated() {
			tabControl.setLabel(title(for: tab), forSegment: index)
		}
		tabControl.invalidateIntrinsicContentSize()
	}

	private func title(for tab: AIPaneTab) -> String {
		switch tab {
		case .rewrite:
			return rewriteViewController.tabTitle
		case .original:
			return "原文"
		case .translation:
			return "翻译"
		}
	}

	/// Opens on the cached rewrite, else on the cached body translation, else on
	/// the original. Only enabled tabs are considered, and the choice itself is
	/// `AIPaneTabPolicy.defaultTab`. The store is read off the main actor, so a
	/// token stops a late answer for an article the reader has already left, or
	/// a tab they already picked, from switching the pane.
	func updateDefaultTab() {
		guard let article else {
			defaultTabToken = UUID()
			show(.original)
			return
		}
		let articleID = article.articleID
		let rewriteEnabled = article.feed?.aiRewriteEnabled ?? true
		let translationEnabled = article.feed?.aiTranslationEnabled ?? true
		let articleAllowsAI = self.articleAllowsAI
		let token = UUID()
		defaultTabToken = token
		show(AIPaneTabPolicy.defaultTab(rewriteEnabled: rewriteEnabled, hasRewrite: false, translationEnabled: translationEnabled, hasBodyTranslation: false, articleAllowsAI: articleAllowsAI))

		guard articleAllowsAI, rewriteEnabled || translationEnabled else {
			return
		}
		Task { @MainActor in
			let hasRewrite = await self.hasCachedRewrite(articleID: articleID)
			guard self.defaultTabToken == token, self.article?.articleID == articleID else {
				return
			}
			var hasBodyTranslation = false
			if translationEnabled {
				hasBodyTranslation = await self.hasBodyTranslation(articleID: articleID)
			}
			guard self.defaultTabToken == token, self.article?.articleID == articleID else {
				return
			}
			self.show(AIPaneTabPolicy.defaultTab(rewriteEnabled: rewriteEnabled, hasRewrite: hasRewrite, translationEnabled: translationEnabled, hasBodyTranslation: hasBodyTranslation, articleAllowsAI: articleAllowsAI))
		}
	}

	private func hasCachedRewrite(articleID: String) async -> Bool {
		guard let rewrite = try? await AIEnvironment.shared.store.rewrite(for: articleID) else {
			return false
		}
		return !rewrite.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private func hasBodyTranslation(articleID: String) async -> Bool {
		guard let translation = try? await AIEnvironment.shared.store.translation(for: articleID) else {
			return false
		}
		return !translation.blocks.isEmpty
	}

	private func show(_ tab: AIPaneTab) {
		selectedTab = tab
		if let index = visibleTabs.firstIndex(of: tab) {
			tabControl.selectedSegment = index
		}
		updateVisibleContent()
	}

	func updateVisibleContent() {
		let showsRewrite = selectedTab == .rewrite && visibleTabs.contains(.rewrite)
		detailViewController.view.isHidden = selectedTab != .original
		rewriteViewController.view.isHidden = !showsRewrite
		translationViewController.view.isHidden = selectedTab != .translation
		translationViewController.setPaneVisible(selectedTab == .translation)
	}

	/// A rewrite that lands while the reader is still on the original takes the
	/// pane, which is where an article that already had one would have opened.
	@objc func rewriteDidBecomeReady(_ notification: Notification) {
		guard let articleID = notification.userInfo?[AIUserInfoKey.articleID] as? String,
		      articleID == article?.articleID,
		      article?.feed?.aiRewriteEnabled == true,
		      articleAllowsAI,
		      selectedTab == .original else {
			return
		}
		defaultTabToken = nil
		show(.rewrite)
	}

	/// A finished body translation opens the translation tab only when the
	/// reader is still on the original, the feed still allows translation and
	/// `AIPaneTabPolicy.defaultTab` does not prefer a cached rewrite.
	@objc func translationDidBecomeReady(_ notification: Notification) {
		guard let articleID = notification.userInfo?[AIUserInfoKey.articleID] as? String,
		      articleID == article?.articleID,
		      article?.feed?.aiTranslationEnabled == true,
		      articleAllowsAI,
		      visibleTabs.contains(.translation),
		      selectedTab == .original else {
			return
		}
		let rewriteEnabled = article?.feed?.aiRewriteEnabled ?? true
		let translationEnabled = article?.feed?.aiTranslationEnabled ?? true
		let allowsAI = articleAllowsAI
		let token = UUID()
		defaultTabToken = token
		Task { @MainActor in
			guard await self.hasBodyTranslation(articleID: articleID),
			      self.defaultTabToken == token,
			      self.article?.articleID == articleID,
			      self.selectedTab == .original else {
				return
			}
			let hasRewrite = rewriteEnabled ? await self.hasCachedRewrite(articleID: articleID) : false
			guard self.defaultTabToken == token, self.article?.articleID == articleID else {
				return
			}
			let tab = AIPaneTabPolicy.defaultTab(rewriteEnabled: rewriteEnabled, hasRewrite: hasRewrite, translationEnabled: translationEnabled, hasBodyTranslation: true, articleAllowsAI: allowsAI)
			guard tab == .translation else {
				return
			}
			self.show(tab)
		}
	}

	@objc func tabChanged(_ sender: NSSegmentedControl) {
		defaultTabToken = nil
		let tabs = visibleTabs
		guard tabs.indices.contains(sender.selectedSegment) else {
			return
		}
		selectedTab = tabs[sender.selectedSegment]
		updateVisibleContent()
		if selectedTab == .rewrite {
			rewriteViewController.refreshIfNeeded()
		}
		// The tab control keeps focus after a click, and it does not route the
		// reading shortcuts, so hand focus to the pane the reader just picked.
		focus()
	}

	/// The feed inspector can turn either AI switch off while its article is on
	/// screen. Tabs disappear immediately; a hidden current tab falls back to a
	/// cached rewrite when rewrites are still on, else to the original. It never
	/// opens translation on its own.
	@objc func feedSettingDidChange(_ notification: Notification) {
		guard let key = notification.userInfo?[Feed.SettingUserInfoKey] as? Feed.SettingKey,
		      key == .aiRewriteEnabled || key == .aiTranslationEnabled,
		      let feed = notification.object as? Feed,
		      article?.feed == feed else {
			return
		}
		// An in-flight default-tab lookup must not override the switch change.
		defaultTabToken = UUID()
		updateTabTitles()
		if visibleTabs.contains(selectedTab) {
			show(selectedTab)
		} else {
			fallbackFromHiddenTab()
		}
		focus()
	}

	private func fallbackFromHiddenTab() {
		guard let articleID = article?.articleID else {
			defaultTabToken = UUID()
			show(.original)
			return
		}
		let rewriteEnabled = article?.feed?.aiRewriteEnabled ?? true
		let allowsAI = articleAllowsAI
		let token = UUID()
		defaultTabToken = token
		show(AIPaneTabPolicy.fallbackTab(rewriteEnabled: rewriteEnabled, hasRewrite: false, articleAllowsAI: allowsAI))
		guard allowsAI, rewriteEnabled else {
			return
		}
		Task { @MainActor in
			let hasRewrite = await self.hasCachedRewrite(articleID: articleID)
			guard self.defaultTabToken == token,
			      self.article?.articleID == articleID,
			      self.selectedTab == .original else {
				return
			}
			self.show(AIPaneTabPolicy.fallbackTab(rewriteEnabled: rewriteEnabled, hasRewrite: hasRewrite, articleAllowsAI: allowsAI))
		}
	}
}
