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

	/// Supplied by the main window. It returns nil in search mode, with no
	/// selection, with multiple selection, or with an unsupported sidebar row;
	/// the panel then stays hidden and the existing “No selection” view shows.
	var jobPanelContextProvider: (() -> AIJobPanelContext?)? {
		didSet {
			updateJobPanel()
		}
	}

	/// Supplied by the main window. Called when the reader clicks a feed row in
	/// the coverage table so the window can switch the sidebar and timeline.
	var onSelectFeed: ((String) -> Void)?

	var article: Article? {
		didSet {
			updateTabBarVisibility()
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
	private let jobStatusView = AIJobStatusView()
	private var tabBarHeightConstraint: NSLayoutConstraint!
	private var selectedTab: AIPaneTab
	private var defaultTabToken: UUID?

	private var jobPanelVisible = false
	private var jobPanelScope: AIJobScope?
	private var jobSnapshot: JobSnapshot?
	private var jobRefreshTask: Task<Void, Never>?
	private var jobRefreshGeneration = UUID()
	private var jobDebounceWorkItem: DispatchWorkItem?
	private var jobPollTimer: Timer?
	private var jobObserverTokens: [NSObjectProtocol] = []
	private var expandedFailureGroups: Set<AIJobFailureGroupKey> = []
	private var retryingFailureGroups: Set<AIJobFailureGroupKey> = []
	private var failureRetryNotices: [AIJobFailureGroupKey: String] = [:]
	private lazy var retryRunner = AIJobFailureRetryRunner(
		enqueuer: AIJobExecutorRetryEnqueuer(executor: AIJobExecutor.shared, store: AIEnvironment.shared.store)
	)

	private struct JobSnapshot {
		let context: AIJobPanelContext
		let activeJobs: [AIJob]
		let foldedFailures: [AIJob]
		let completedTodayJobs: [AIJob]
		let articlesByID: [String: AIJobArticleInfo]
		let coverage: AIJobCoverage?
		let coverageQueryFailed: Bool
		let now: Date
	}

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

		tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 34)

		NSLayoutConstraint.activate([
			tabBar.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),
			tabBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
			tabBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
			tabBarHeightConstraint,
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

		jobStatusView.translatesAutoresizingMaskIntoConstraints = false
		jobStatusView.isHidden = true
		contentView.addSubview(jobStatusView)
		jobStatusView.onOpenSettings = { [weak self] in
			self?.openAISettings()
		}
		jobStatusView.onSelectFeed = { [weak self] feedID in
			self?.onSelectFeed?(feedID)
		}
		jobStatusView.onToggleFailureGroup = { [weak self] key in
			self?.toggleFailureGroup(key)
		}
		jobStatusView.onRetryFailureGroup = { [weak self] key, requests in
			self?.retryFailureGroup(key, requests: requests)
		}

		for childView in [detailView, rewriteView, translationView, jobStatusView] {
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
		installJobPanelObservers()
		updateTabTitles()
		if !visibleTabs.contains(selectedTab) {
			selectedTab = .original
		}
		show(selectedTab)
		updateTabBarVisibility()
	}

	isolated deinit {
		jobPollTimer?.invalidate()
		for token in jobObserverTokens {
			NotificationCenter.default.removeObserver(token)
		}
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

	/// The tab bar belongs to the selected article: without one there is nothing
	/// to switch between, so hide the bar and let the content view take its full
	/// height instead of keeping an empty strip above "No selection".
	private func updateTabBarVisibility() {
		guard isViewLoaded else {
			return
		}
		let hidesTabBar = article == nil
		tabBar.isHidden = hidesTabBar
		tabBarHeightConstraint.constant = hidesTabBar ? 0 : 34
		updateJobPanel()
	}

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

// MARK: - Job panel

extension AIDetailPaneViewController {

	/// Shows the right-pane task panel only when no article is selected and the
	/// window supplied a supported sidebar scope. Search mode, multiple
	/// selection, account rows and the Smart Feeds group return no context, so
	/// the existing “No selection” view stays in place.
	func updateJobPanel() {
		guard isViewLoaded else {
			return
		}
		guard article == nil, let context = jobPanelContextProvider?() else {
			hideJobPanel()
			return
		}
		let wasVisible = jobPanelVisible
		let scopeChanged = jobPanelScope != context.scope
		if scopeChanged || !wasVisible {
			jobSnapshot = nil
			jobStatusView.clear()
		}
		jobPanelScope = context.scope
		jobPanelVisible = true
		jobStatusView.isHidden = false
		startJobPanelTimers()
		scheduleJobPanelRefresh(immediate: true)
	}

	/// Called by the main window after the timeline finishes a fetch, so a read
	/// filter change is reflected without waiting for the five-second poll.
	func refreshJobPanelFromTimelineChange() {
		updateJobPanel()
	}
}

private extension AIDetailPaneViewController {

	func hideJobPanel() {
		guard jobPanelVisible || !jobStatusView.isHidden else {
			return
		}
		jobPanelVisible = false
		jobPanelScope = nil
		jobSnapshot = nil
		jobRefreshGeneration = UUID()
		jobRefreshTask?.cancel()
		jobRefreshTask = nil
		jobDebounceWorkItem?.cancel()
		jobDebounceWorkItem = nil
		stopJobPanelTimers()
		jobStatusView.isHidden = true
		jobStatusView.clear()
	}

	func startJobPanelTimers() {
		if jobPollTimer == nil {
			let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.refreshJobPanel()
				}
			}
			RunLoop.main.add(timer, forMode: .common)
			jobPollTimer = timer
		}
	}

	func stopJobPanelTimers() {
		jobPollTimer?.invalidate()
		jobPollTimer = nil
	}

	func installJobPanelObservers() {
		guard jobObserverTokens.isEmpty else {
			return
		}
		let names: [Notification.Name] = [.aiJobsDidChange, .aiTranslationReady, .aiRewriteReady, .aiRewriteStored, .aiRewriteRemoved, .aiJobFailed]
		for name in names {
			let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.scheduleJobPanelRefresh()
				}
			}
			jobObserverTokens.append(token)
		}
	}

	func scheduleJobPanelRefresh(immediate: Bool = false) {
		jobDebounceWorkItem?.cancel()
		jobDebounceWorkItem = nil
		guard !immediate else {
			refreshJobPanel()
			return
		}
		let work = DispatchWorkItem { [weak self] in
			Task { @MainActor [weak self] in
				self?.refreshJobPanel()
			}
		}
		jobDebounceWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
	}

	func refreshJobPanel() {
		guard jobPanelVisible, article == nil, let context = jobPanelContextProvider?() else {
			return
		}
		let generation = UUID()
		jobRefreshGeneration = generation
		jobRefreshTask?.cancel()
		jobRefreshTask = Task { @MainActor [weak self] in
			guard let self else {
				return
			}
			let now = Date()
			let store = AIEnvironment.shared.store
			let since = now.addingTimeInterval(-24 * 60 * 60)
			let activeJobs: [AIJob]
			let foldedFailures: [AIJob]
			let completedTodayJobs: [AIJob]
			do {
				async let active = store.activeJobs()
				async let folded = store.foldedFailures(since: since)
				async let completedToday = store.recentJobs(status: .completed, since: AIJobStatusModel.startOfDay(for: now), limit: 3000)
				activeJobs = try await active
				foldedFailures = try await folded
				completedTodayJobs = try await completedToday
			} catch {
				return
			}
			guard self.jobRefreshGeneration == generation, self.jobPanelVisible else {
				return
			}

			let articleIDs = Set(activeJobs.map(\.articleID))
				.union(foldedFailures.map(\.articleID))
				.union(completedTodayJobs.map(\.articleID))
			let articles: Set<Article>
			if articleIDs.isEmpty {
				articles = []
			} else if articleIDs.count > 1000 {
				var merged: Set<Article> = []
				let ids = Array(articleIDs)
				var start = 0
				while start < ids.count {
					if Task.isCancelled {
						return
					}
					let end = min(start + 500, ids.count)
					let batch = Set(ids[start..<end])
					let fetched = await AccountManager.shared.fetchArticlesAsync(.articleIDs(batch))
					merged.formUnion(fetched)
					start = end
				}
				articles = merged
			} else {
				articles = await AccountManager.shared.fetchArticlesAsync(.articleIDs(articleIDs))
			}
			let articlesByID = Dictionary(articles.map { ($0.articleID, AIJobArticleInfo(article: $0)) }, uniquingKeysWith: { first, _ in first })

			let visibleIDs = context.timelineArticleIDs
			var coverage: AIJobCoverage?
			var coverageQueryFailed = false
			if visibleIDs.isEmpty {
				coverage = AIJobCoverageBuilder.build(
					articles: [],
					unreadOnly: context.unreadOnly,
					feedDisplayNames: context.feedDisplayNames,
					translatedArticleIDs: [],
					rewrittenArticleIDs: []
				)
			} else {
				do {
					async let translated = store.completedTranslationArticleIDs(for: visibleIDs)
					async let rewritten = store.completedRewriteArticleIDs(for: visibleIDs)
					coverage = AIJobCoverageBuilder.build(
						articles: context.articles,
						unreadOnly: context.unreadOnly,
						feedDisplayNames: context.feedDisplayNames,
						translatedArticleIDs: try await translated,
						rewrittenArticleIDs: try await rewritten
					)
				} catch {
					coverage = nil
					coverageQueryFailed = true
				}
			}

			guard self.jobRefreshGeneration == generation, self.jobPanelVisible else {
				return
			}
			self.jobSnapshot = JobSnapshot(
				context: context,
				activeJobs: activeJobs,
				foldedFailures: foldedFailures,
				completedTodayJobs: completedTodayJobs,
				articlesByID: articlesByID,
				coverage: coverage,
				coverageQueryFailed: coverageQueryFailed,
				now: now
			)
			self.renderJobPanel()
		}
	}

	func renderJobPanel() {
		guard jobPanelVisible, let snapshot = jobSnapshot else {
			return
		}
		let input = AIJobStatusInput(
			scope: snapshot.context.scope,
			now: snapshot.now,
			hasAPIKey: AIEnvironment.shared.hasAPIKey,
			activeJobs: snapshot.activeJobs,
			foldedFailures: snapshot.foldedFailures,
			completedTodayJobs: snapshot.completedTodayJobs,
			articlesByID: snapshot.articlesByID,
			timelineArticleCount: snapshot.context.timelineArticleCount,
			unreadOnly: snapshot.context.unreadOnly,
			coverage: snapshot.coverage,
			coverageQueryFailed: snapshot.coverageQueryFailed,
			feedDisplayNames: snapshot.context.feedDisplayNames,
			expandedFailureGroups: expandedFailureGroups,
			retryingFailureGroups: retryingFailureGroups,
			failureRetryNotices: failureRetryNotices
		)
		jobStatusView.render(AIJobStatusModel.build(input))
	}

	func toggleFailureGroup(_ key: AIJobFailureGroupKey) {
		if expandedFailureGroups.contains(key) {
			expandedFailureGroups.remove(key)
		} else {
			expandedFailureGroups.insert(key)
		}
		renderJobPanel()
	}

	/// “Retry all” goes through the executor's manual enqueue paths. The runner
	/// reserves each article + kind before its first await, so a double click
	/// cannot submit the same job twice, and a concurrent catch-up pass wins or
	/// loses the same reservation exactly once.
	func retryFailureGroup(_ key: AIJobFailureGroupKey, requests: [AIJobRequeueRequest]) {
		guard !retryingFailureGroups.contains(key) else {
			return
		}
		retryingFailureGroups.insert(key)
		failureRetryNotices[key] = nil
		renderJobPanel()
		Task { @MainActor [weak self] in
			guard let self else {
				return
			}
			let outcome = await self.retryRunner.retry(requests)
			self.retryingFailureGroups.remove(key)
			self.failureRetryNotices[key] = outcome.skippedCount > 0 ? "已跳过 \(outcome.skippedCount) 项" : nil
			self.renderJobPanel()
			self.scheduleJobPanelRefresh()
		}
	}

	func openAISettings() {
		NSApp.sendAction(#selector(AppDelegate.showAIPreferences(_:)), to: nil, from: self)
	}
}
