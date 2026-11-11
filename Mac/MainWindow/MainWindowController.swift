//
//  MainWindowController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 8/1/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import AppKit
import os
import UserNotifications
import Articles
import Account
import RSCore

enum TimelineSourceMode {
	case regular, search
}

final class MainWindowController: NSWindowController, NSUserInterfaceValidations {
	static private let logger = Logger(subsystem: Logger.nnwSubsystem, category: "MainWindowController")

    private var activityManager = ActivityManager()

	private var isShowingExtractedArticle = false
	private var articleExtractor: ArticleExtractor?
	private var sharingServicePickerDelegate: SharingServicePickerDelegate?

	private let windowAutosaveName = NSWindow.FrameAutosaveName("MainWindow")
	private static let mainWindowWidthsStateKey = "mainWindowWidthsStateKey"

	private var currentFeedOrFolder: AnyObject? {
		// Nil for none or multiple selection.
		guard let selectedObjects = selectedObjectsInSidebar(), selectedObjects.count == 1 else {
			return nil
		}
		return selectedObjects.first
	}

	private var shareToolbarItem: NSToolbarItem? {
		return window?.toolbar?.existingItem(withIdentifier: .share)
	}

	private static let detailViewMinimumWidth = 384
	private static let detailViewMinimumHeight: CGFloat = 200
	private static let timelineMinimumHeight: CGFloat = 120
	private static let sidebarMinimumWidth: CGFloat = 96
	private static let aiPaneMinimumWidth: CGFloat = 280
	private static let aiPaneDefaultWidth = 340
	// Used for the timeline when column layout has no saved height.
	private static let defaultColumnLayoutTimelineHeightFraction: CGFloat = 0.4
	private static let sidebarHoldingPriority: Float = 260
	private static let timelineHoldingPriority: Float = 255
	private static let aiPaneHoldingPriority: Float = 250
	private static let toolbarIdentifier = "MainWindowToolbar"
	private var splitViewController: NSSplitViewController?
	// Column layout only: the vertical split holding the timeline above the article view.
	private var contentSplitViewController: NSSplitViewController?
	private var timelineLayout = AppDefaults.timelineLayout
	// Geometry for the layout that isn’t showing, so a round trip through the other layout keeps it.
	private var rememberedStandardLayoutWidths = [Int]()
	private var rememberedColumnLayoutTimelineHeight = 0
	private var sidebarViewController: SidebarViewController?
	private var timelineContainerViewController: TimelineContainerViewController?
	private var detailViewController: DetailViewController?
	private var detailPaneViewController: AIDetailPaneViewController?
	private var aiViewController: AIChatViewController?
	private var aiSplitViewItem: NSSplitViewItem?
	private var isAIPaneVisible = false
	private var rememberedAIPaneWidth = MainWindowController.aiPaneDefaultWidth
	private var isUserResizingAIPane = false
	/// The timeline posts after every fetch; the panel recalculates immediately
	/// instead of waiting for its five-second poll. Both are injectable so tests
	/// can assert the wiring without a live timeline.
	var aiJobPanelRefreshCenter: NotificationCenter = .default
	var aiJobPanelRefreshHandler: (() -> Void)?
	private var timelineRefreshToken: NSObjectProtocol?
	private var currentSearchField: NSSearchField?
	private var searchString: String?
	private var lastSentSearchString: String?
	private var timelineSourceMode: TimelineSourceMode = .regular {
		didSet {
			timelineContainerViewController?.showTimeline(for: timelineSourceMode)
			detailViewController?.showDetail(for: timelineSourceMode)
			updateStatusBarLink()
			updateAIPaneArticle()
			detailPaneViewController?.updateJobPanel()
		}
	}
	private var searchSmartFeed: SmartFeed?
	private var restoreArticleWindowScrollY: CGFloat?
	// Holds the split view controller and the status bar.
	private let mainWindowContentViewController = MainWindowContentViewController()
	private var mouseoverLink: String? {
		didSet {
			updateStatusBarLink()
		}
	}

	// MARK: - NSWindowController

	isolated deinit {
		if let timelineRefreshToken {
			aiJobPanelRefreshCenter.removeObserver(timelineRefreshToken)
		}
	}

	convenience init() {
		self.init(windowNibName: "MainWindow")
	}

	override func windowDidLoad() {
		super.windowDidLoad()

		if let window = window {
			let point = NSPoint(x: 128, y: 64)
			let size = NSSize(width: 1345, height: 900)
			let minSize = NSSize(width: 600, height: 600)
			window.setPointAndSizeAdjustingForScreen(point: point, size: size, minimumSize: minSize)
		}

		// The three panes live for the window’s life. Switching layout rebuilds only the split views around them.
		let sidebarViewController = SidebarViewController()
		sidebarViewController.delegate = self
		sidebarViewController.view.translatesAutoresizingMaskIntoConstraints = false
		sidebarViewController.view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.sidebarMinimumWidth).isActive = true
		self.sidebarViewController = sidebarViewController

		let timelineContainerViewController = TimelineContainerViewController()
		timelineContainerViewController.delegate = self
		self.timelineContainerViewController = timelineContainerViewController

		let detailViewController = DetailViewController()
		detailViewController.delegate = self
		self.detailViewController = detailViewController

		let detailPaneViewController = AIDetailPaneViewController(detailViewController: detailViewController)
		detailPaneViewController.jobPanelContextProvider = { [weak self] in
			self?.currentAIJobPanelContext()
		}
		detailPaneViewController.onSelectFeed = { [weak self] feedID in
			self?.selectFeedInSidebar(feedID: feedID)
		}
		self.detailPaneViewController = detailPaneViewController
		installTimelineRefreshObservation()

		let aiViewController = AIChatViewController()
		aiViewController.selectedTextProvider = { [weak self] completion in
			self?.fetchSelectedTextForAI(completion)
		}
		aiViewController.onEscape = { [weak self] in
			self?.detailPaneViewController?.focus()
		}
		self.aiViewController = aiViewController

		mainWindowContentViewController.statusBarView.delegate = self
		updateStatusBarVisibility()

		installSplitViewController(for: timelineLayout)

		sharingServicePickerDelegate = SharingServicePickerDelegate(self.window)

		NotificationCenter.default.addObserver(self, selector: #selector(handleUserDefaultsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(refreshProgressDidChange(_:)), name: .AccountRefreshDidBegin, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(refreshProgressDidChange(_:)), name: .AccountRefreshDidFinish, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(refreshProgressDidChange(_:)), name: .progressInfoDidChange, object: CombinedRefreshProgress.shared)

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleUnreadCountDisplaySettingDidChange(_:)), name: .unreadCountDisplaySettingDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange(_:)), name: .DisplayNameDidChange, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(articleThemeNamesDidChangeNotification(_:)), name: .ArticleThemeNamesDidChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(currentArticleThemeDidChangeNotification(_:)), name: .CurrentArticleThemeDidChangeNotification, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(handleAIAskRequested(_:)), name: .aiAskRequested, object: nil)

		DispatchQueue.main.async {
			self.updateWindowTitle()
		}

	}

	// MARK: - API

	func selectedObjectsInSidebar() -> [AnyObject]? {
		return sidebarViewController?.selectedObjects
	}

	/// The task panel only understands the five scopes in the design. Anything
	/// else (search, no selection, multiple selection, an account row or the
	/// Smart Feeds group) returns nil and the panel stays hidden.
	func currentAIJobPanelContext() -> AIJobPanelContext? {
		guard timelineSourceMode == .regular else {
			return nil
		}
		guard let selectedObjects = selectedObjectsInSidebar(), selectedObjects.count == 1, let object = selectedObjects.first else {
			return nil
		}
		guard let scope = aiJobScope(for: object) else {
			return nil
		}
		let timeline = currentTimelineViewController
		let timelineArticles = timeline?.articles ?? []
		var feedDisplayNames: [String: String] = [:]
		for article in timelineArticles {
			let host = article.feed.flatMap { URL(string: $0.url)?.host }
			feedDisplayNames[article.feedID] = AIJobCoverageBuilder.feedDisplayName(
				feedName: article.feed?.nameForDisplay,
				urlHost: host,
				feedID: article.feedID
			)
		}
		return AIJobPanelContext(
			scope: scope,
			articles: timelineArticles.map { AIJobArticleInfo(article: $0) },
			feedDisplayNames: feedDisplayNames,
			unreadOnly: timeline?.isReadFiltered == true
		)
	}

	/// Installs the timeline-fetch observer. Idempotent so tests and the window
	/// setup can both call it.
	func installTimelineRefreshObservation() {
		guard timelineRefreshToken == nil else {
			return
		}
		timelineRefreshToken = aiJobPanelRefreshCenter.addObserver(forName: .aiTimelineArticlesDidChange, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.handleTimelineArticlesDidChange()
			}
		}
	}

	func handleTimelineArticlesDidChange() {
		if let aiJobPanelRefreshHandler {
			aiJobPanelRefreshHandler()
			return
		}
		detailPaneViewController?.refreshJobPanelFromTimelineChange()
	}

	private func aiJobScope(for object: AnyObject) -> AIJobScope? {
		if let feed = object as? Feed {
			return AIJobScope(kind: .feed, name: feed.nameForDisplay, feedIDs: [feed.feedID], feedCount: 1)
		}
		if let folder = object as? Folder {
			let feeds = folder.flattenedFeeds()
			return AIJobScope(kind: .folder, name: folder.nameForDisplay, feedIDs: Set(feeds.map(\.feedID)), feedCount: feeds.count)
		}
		let smartFeeds = SmartFeedsController.shared
		if object === smartFeeds.todayFeed {
			return AIJobScope(kind: .today, name: smartFeeds.todayFeed.nameForDisplay)
		}
		if object === smartFeeds.unreadFeed {
			return AIJobScope(kind: .allUnread, name: smartFeeds.unreadFeed.nameForDisplay)
		}
		if object === smartFeeds.starredFeed {
			return AIJobScope(kind: .starred, name: smartFeeds.starredFeed.nameForDisplay)
		}
		return nil
	}

	private func selectTimelineArticle(_ articleID: String) {
		guard let timeline = currentTimelineViewController,
		      let index = timeline.articles.firstIndex(where: { $0.articleID == articleID }) else {
			return
		}
		timeline.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
		timeline.tableView.scrollTo(row: index)
		timeline.focus()
	}

	func selectedContainerInSidebar() -> Container? {
		sidebarViewController?.selectedContainer
	}

	func selectFeedInSidebar(_ feed: Feed) {
		sidebarViewController?.selectFeed(feed)
	}

	/// Switches the window to a feed chosen in the AI task board. Unknown feeds
	/// are ignored so a stale row cannot produce an error.
	func selectFeedInSidebar(feedID: String) {
		guard let feed = feed(withFeedID: feedID) else {
			return
		}
		selectFeedInSidebar(feed)
	}

	private func feed(withFeedID feedID: String) -> Feed? {
		for account in AccountManager.shared.accounts {
			if let feed = account.existingFeed(withFeedID: feedID) {
				return feed
			}
		}
		return nil
	}

	func handle(_ response: UNNotificationResponse) {
		let userInfo = response.notification.request.content.userInfo
		guard let articlePathUserInfo = userInfo[UserInfoKey.articlePath] as? [AnyHashable: Any] else { return }
		sidebarViewController?.deepLinkRevealAndSelect(for: articlePathUserInfo)
		currentTimelineViewController?.goToDeepLink(for: articlePathUserInfo)
	}

	func handle(_ activity: NSUserActivity) {
		guard let userInfo = activity.userInfo else { return }
		guard let articlePathUserInfo = userInfo[UserInfoKey.articlePath] as? [AnyHashable: Any] else { return }
		sidebarViewController?.deepLinkRevealAndSelect(for: articlePathUserInfo)
		currentTimelineViewController?.goToDeepLink(for: articlePathUserInfo)
	}

	func saveStateToUserDefaults() {
		let state = savableState()
		Self.logger.debug("MainWindowController: Saving state to UserDefaults: \(state)")
		let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
		AppDefaults.secureWindowState = data
		// Don't save the frame in full screen — it would replace the saved windowed frame with the screen's frame.
		if let window, !window.styleMask.contains(.fullScreen) {
			window.saveFrame(usingName: windowAutosaveName)
		}
	}

	func restoreStateFromUserDefaults() {
		if let data = AppDefaults.secureWindowState,
		   let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MainWindowState.self, from: data) {
			Self.logger.debug("MainWindowController: restoring state from UserDefaults: \(state)")
			window?.setFrameUsingName(windowAutosaveName, force: true)
			restoreState(from: state)
		} else if let state = AppDefaults.legacyWindowState {
			// Migrate from previous window state data. Delete data when finished.
			window?.setFrameUsingName(windowAutosaveName, force: true)
			restoreLegacyState(from: state)
			AppDefaults.deleteLegacyWindowState()
		}
	}

	// MARK: - Notifications

	@objc nonisolated func handleUserDefaultsDidChange(_ note: Notification) {
		Task { @MainActor in
			self.userDefaultsDidChange()
		}
	}

	@objc nonisolated func handleAIAskRequested(_ note: Notification) {
		Task { @MainActor in
			self.setAIPaneVisible(!self.isAIPaneVisible, focus: false)
		}
	}

	private func userDefaultsDidChange() {
		let layout = AppDefaults.timelineLayout
		if layout != timelineLayout {
			installSplitViewController(for: layout)
		}
		updateStatusBarVisibility()
	}

	@objc func refreshProgressDidChange(_ note: Notification) {
		CoalescingQueue.standard.add(self, #selector(makeToolbarValidate))
	}

	@objc func unreadCountDidChange(_ note: Notification) {
		CoalescingQueue.standard.add(self, #selector(coalescedUpdateWindowTitle))
	}

	@objc func handleUnreadCountDisplaySettingDidChange(_ notification: Notification) {
		updateWindowTitle()
	}

	@objc func coalescedUpdateWindowTitle() {
		updateWindowTitle()
	}

	@objc func displayNameDidChange(_ note: Notification) {
		updateWindowTitleIfNecessary(note.object)
	}

	@objc func articleThemeNamesDidChangeNotification(_ note: Notification) {
		updateArticleThemeMenu()
	}

	@objc func currentArticleThemeDidChangeNotification(_ note: Notification) {
		updateArticleThemeMenu()
	}

	private func updateWindowTitleIfNecessary(_ noteObject: Any?) {

		if let folder = currentFeedOrFolder as? Folder, let noteObject = noteObject as? Folder {
			if folder == noteObject {
				updateWindowTitle()
				return
			}
		}

		if let feed = currentFeedOrFolder as? Feed, let noteObject = noteObject as? Feed {
			if feed == noteObject {
				updateWindowTitle()
				return
			}
		}

		// If we don't recognize the changed object, we will test it for identity instead
		// of equality.  This works well for us if the window title is displaying a
		// PsuedoFeed object.
		if let currentObject = currentFeedOrFolder, let noteObject = noteObject {
			if currentObject === noteObject as AnyObject {
				updateWindowTitle()
			}
		}

	}

	// MARK: - Toolbar

	@objc func makeToolbarValidate() {

		window?.toolbar?.validateVisibleItems()
	}

	// MARK: - NSUserInterfaceValidations

	public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {

		if item.action == #selector(copyArticleURL(_:)) {
			return canCopyArticleURL()
		}

		if item.action == #selector(copyExternalURL(_:)) {
			return canCopyExternalURL()
		}

		if item.action == #selector(openArticleInBrowser(_:)) {
			if let item = item as? NSMenuItem, item.keyEquivalentModifierMask.contains(.shift) {
				item.title = Browser.titleForOpenInBrowserInverted
			}

			return currentLink != nil
		}

		if item.action == #selector(nextUnread(_:)) {
			return canGoToNextUnread(wrappingToTop: true)
		}

		if item.action == #selector(markAllAsRead(_:)) {
			return canMarkAllAsRead()
		}

		if item.action == #selector(toggleRead(_:)) {
			return validateToggleRead(item)
		}

		if item.action == #selector(toggleStarred(_:)) {
			return validateToggleStarred(item)
		}

		if item.action == #selector(markAboveArticlesAsRead(_:)) {
			return canMarkAboveArticlesAsRead()
		}

		if item.action == #selector(markBelowArticlesAsRead(_:)) {
			return canMarkBelowArticlesAsRead()
		}

		if item.action == #selector(toggleArticleExtractor(_:)) {
			return validateToggleArticleExtractor(item)
		}

		if item.action == #selector(toggleAIPane(_:)) {
			if let menuItem = item as? NSMenuItem {
				menuItem.state = isAIPaneVisible ? .on : .off
			}
			return true
		}

		if item.action == #selector(toolbarShowShareMenu(_:)) {
			return canShowShareMenu()
		}

		if item.action == #selector(moveFocusToSearchField(_:)) {
			return currentSearchField != nil
		}

		if item.action == #selector(cleanUp(_:)) {
			return validateCleanUp(item)
		}

		if item.action == #selector(toggleReadFeedsFilter(_:)) {
			return validateToggleReadFeeds(item)
		}

		if item.action == #selector(toggleReadArticlesFilter(_:)) {
			return validateToggleReadArticles(item)
		}

		if item.action == #selector(sortArticlesByField(_:)) {
			return validateSortArticlesByField(item)
		}

		if item.action == #selector(sortArticlesAscending(_:)) {
			return validateSortDirection(item, direction: .orderedAscending)
		}

		if item.action == #selector(sortArticlesDescending(_:)) {
			return validateSortDirection(item, direction: .orderedDescending)
		}

		if let isShown = SidebarViewController.smartFeedIsShown(forGoToAction: item.action) {
			return isShown
		}

		return true
	}

	// MARK: - Actions

	@IBAction func scrollOrGoToNextUnread(_ sender: Any?) {
		guard let detailViewController else {
			return
		}
		Task { @MainActor in
			let canScroll = await detailViewController.canScrollDown()
			NSCursor.setHiddenUntilMouseMoves(true)
			if canScroll {
				detailViewController.scrollPageDown(sender)
			} else {
				nextUnread(sender)
			}
		}
	}

	@IBAction func scrollUp(_ sender: Any?) {
		guard let detailViewController else {
			return
		}
		Task { @MainActor in
			let canScroll = await detailViewController.canScrollUp()
			if canScroll {
				NSCursor.setHiddenUntilMouseMoves(true)
				detailViewController.scrollPageUp(sender)
			}
		}
	}

	@IBAction func copyArticleURL(_ sender: Any?) {
		guard let articles = selectedArticles else {
			assertionFailure("Expected selectedArticles to be non-nil")
			return
		}
		let links = articles.compactMap { $0.preferredLink }
		if links.isEmpty {
			assertionFailure("Expected at least one link")
			return
		}

		URLPasteboardWriter.write(urlStrings: links, to: .general)
	}

	@IBAction func copyExternalURL(_ sender: Any?) {
		guard let articles = selectedArticles else {
			assertionFailure("Expected selectedArticles to be non-nil")
			return
		}
		let links = articles.compactMap { $0.externalLink }
		if links.isEmpty {
			assertionFailure("Expected at least one link")
			return
		}

		URLPasteboardWriter.write(urlStrings: links, to: .general)
	}

	@IBAction func openArticleInBrowser(_ sender: Any?) {
		if let link = currentLink {
			Browser.open(link, invertPreference: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
		}
	}

	@IBAction func openInBrowser(_ sender: Any?) {
		if AppDefaults.openInBrowserInBackground {
			window?.makeKeyAndOrderFront(self)
		}
		openArticleInBrowser(sender)
	}

	@objc func openInAppBrowser(_ sender: Any?) {
		// There is no In-App Browser for mac - so we use safari
		openArticleInBrowser(sender)
	}

	@IBAction func openInBrowserUsingOppositeOfSettings(_ sender: Any?) {
		if !AppDefaults.openInBrowserInBackground {
			window?.makeKeyAndOrderFront(self)
		}
		if let link = currentLink {
			Browser.open(link, inBackground: !AppDefaults.openInBrowserInBackground)
		}
	}

	@IBAction func nextUnread(_ sender: Any?) {
		guard let timelineViewController = currentTimelineViewController, let sidebarViewController = sidebarViewController else {
			return
		}

		// Flush coalesced unread-count updates so folder counts are current.
		CoalescingQueue.standard.performCallsImmediately()

		NSCursor.setHiddenUntilMouseMoves(true)

		// TODO: handle search mode
		if timelineViewController.canGoToNextUnread(wrappingToTop: false) {
			goToNextUnreadInTimeline(wrappingToTop: false)
		} else if sidebarViewController.canGoToNextUnread(wrappingToTop: true) {
			sidebarViewController.goToNextUnread(wrappingToTop: true)

			// If we ended up on the same timelineViewController, we may need to wrap
			// around to the top of its contents.
			if timelineViewController.canGoToNextUnread(wrappingToTop: true) {
				goToNextUnreadInTimeline(wrappingToTop: true)
			}
		}
	}

	@IBAction func markAllAsRead(_ sender: Any?) {
		currentTimelineViewController?.markAllAsRead()
	}

	@IBAction func toggleRead(_ sender: Any?) {
		currentTimelineViewController?.toggleReadStatusForSelectedArticles()
	}

	@IBAction func markRead(_ sender: Any?) {
		currentTimelineViewController?.markSelectedArticlesAsRead(sender)
	}

	@IBAction func markUnread(_ sender: Any?) {
		currentTimelineViewController?.markSelectedArticlesAsUnread(sender)
	}

	@IBAction func toggleStarred(_ sender: Any?) {
		currentTimelineViewController?.toggleStarredStatusForSelectedArticles()
	}

	@IBAction func toggleArticleExtractor(_ sender: Any?) {

		guard let currentLink = currentLink, let article = oneSelectedArticle else {
			return
		}

		defer {
			makeToolbarValidate()
		}

		if articleExtractor?.state == .failedToParse {
			startArticleExtractorForCurrentLink()
			return
		}

		guard articleExtractor?.state != .processing else {
			articleExtractor?.cancel()
			articleExtractor = nil
			isShowingExtractedArticle = false
			detailViewController?.setState(DetailState.article(article, nil), mode: timelineSourceMode)
			return
		}

		guard !isShowingExtractedArticle else {
			isShowingExtractedArticle = false
			detailViewController?.setState(DetailState.article(article, nil), mode: timelineSourceMode)
			return
		}

		if let articleExtractor = articleExtractor, let extractedArticle = articleExtractor.article {
			if currentLink == articleExtractor.articleLink {
				isShowingExtractedArticle = true
				let detailState = DetailState.extracted(article, extractedArticle, nil)
				detailViewController?.setState(detailState, mode: timelineSourceMode)
			}
		} else {
			startArticleExtractorForCurrentLink()
		}

	}

	@IBAction func markAllAsReadAndGoToNextUnread(_ sender: Any?) {
		currentTimelineViewController?.markAllAsRead {
			self.nextUnread(sender)
		}
	}

	@IBAction func markUnreadAndGoToNextUnread(_ sender: Any?) {
		markUnread(sender)
		nextUnread(sender)
	}

	@IBAction func markReadAndGoToNextUnread(_ sender: Any?) {
		markUnread(sender)
		nextUnread(sender)
	}

	@IBAction func markOlderArticlesAsRead(_ sender: Any?) {
		currentTimelineViewController?.markOlderArticlesRead()
	}

	@IBAction func markAboveArticlesAsRead(_ sender: Any?) {
		currentTimelineViewController?.markAboveArticlesRead()
	}

	@IBAction func markBelowArticlesAsRead(_ sender: Any?) {
		currentTimelineViewController?.markBelowArticlesRead()
	}

	@IBAction func navigateToTimeline(_ sender: Any?) {
		currentTimelineViewController?.focus()
	}

	@IBAction func navigateToSidebar(_ sender: Any?) {
		sidebarViewController?.focus()
	}

	@IBAction func navigateToDetail(_ sender: Any?) {
		detailPaneViewController?.focus()
	}

	@IBAction func toggleAIPane(_ sender: Any?) {
		setAIPaneVisible(!isAIPaneVisible, focus: true)
	}

	@IBAction func goToPreviousSubscription(_ sender: Any?) {
		sidebarViewController?.outlineView.selectPreviousRow(sender)
	}

	@IBAction func goToNextSubscription(_ sender: Any?) {
		sidebarViewController?.outlineView.selectNextRow(sender)
	}

	@IBAction func gotoToday(_ sender: Any?) {
		sidebarViewController?.gotoToday(sender)
	}

	@IBAction func gotoAllUnread(_ sender: Any?) {
		sidebarViewController?.gotoAllUnread(sender)
	}

	@IBAction func gotoStarred(_ sender: Any?) {
		sidebarViewController?.gotoStarred(sender)
	}

	@IBAction func toolbarShowShareMenu(_ sender: Any?) {
		guard let selectedArticles = selectedArticles, !selectedArticles.isEmpty else {
			assertionFailure("Expected toolbarShowShareMenu to be called only when there are selected articles.")
			return
		}
		guard let shareToolbarItem = shareToolbarItem else {
			assertionFailure("Expected toolbarShowShareMenu to be called only by the Share item in the toolbar.")
			return
		}
		// In the toolbar's Text Only mode or overflow menu the item's view isn't on-window, so anchor the picker to the window instead.
		let anchorView: NSView
		let anchorRect: NSRect
		if let view = shareToolbarItem.view, view.window != nil {
			anchorView = view
			anchorRect = view.bounds
		} else if let contentView = window?.contentView {
			anchorView = contentView
			anchorRect = NSRect(x: contentView.frame.width / 2.0, y: contentView.frame.height - 4, width: 1, height: 1)
		} else {
			return
		}

		let sortedArticles = selectedArticles.sortedByDate(.orderedAscending)
		let items = sortedArticles.map { ArticlePasteboardWriter(article: $0) }

		detailViewController?.fetchSelectedHTML { selectedHTML in
			self.sharingServicePickerDelegate?.selectedHTML = selectedHTML
			let sharingServicePicker = NSSharingServicePicker(items: items)
			sharingServicePicker.delegate = self.sharingServicePickerDelegate
			sharingServicePicker.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
		}
	}

	@IBAction func moveFocusToSearchField(_ sender: Any?) {
		// The search field lives in the toolbar — show it if hidden.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4896>
		if let toolbar = window?.toolbar, !toolbar.isVisible {
			toolbar.isVisible = true
		}
		guard let searchField = currentSearchField else {
			return
		}
		window?.makeFirstResponder(searchField)
	}

	@IBAction func cleanUp(_ sender: Any?) {
		timelineContainerViewController?.cleanUp()
	}

	@IBAction func toggleReadFeedsFilter(_ sender: Any?) {
		sidebarViewController?.toggleReadFilter()
	}

	@IBAction func toggleReadArticlesFilter(_ sender: Any?) {
		timelineContainerViewController?.toggleReadFilter()
	}

	@IBAction func sortArticlesByField(_ sender: NSMenuItem) {
		// The menu item’s identifier is the ArticleSortKey raw value.
		guard let identifier = sender.identifier, let key = ArticleSortKey(rawValue: identifier.rawValue) else {
			return
		}
		timelineContainerViewController?.sortBy(key: key)
	}

	@IBAction func sortArticlesAscending(_ sender: Any?) {
		timelineContainerViewController?.setSortDirection(.orderedAscending)
	}

	@IBAction func sortArticlesDescending(_ sender: Any?) {
		timelineContainerViewController?.setSortDirection(.orderedDescending)
	}

	@objc func selectArticleTheme(_ menuItem: NSMenuItem) {
		ArticleThemesManager.shared.currentThemeName = menuItem.title
	}
}

// MARK: NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

	func window(_ window: NSWindow, willEncodeRestorableState coder: NSCoder) {
		let state = savableState()
		Self.logger.debug("MainWindowController: willEncodeRestorableState: \(state)")
		coder.encode(state, forKey: UserInfoKey.windowState)
	}

	func window(_ window: NSWindow, didDecodeRestorableState coder: NSCoder) {
		guard let state = coder.decodeObject(of: MainWindowState.self, forKey: UserInfoKey.windowState) else {
			Self.logger.debug("MainWindowController: failed to decode restorable state")
			return
		}
		Self.logger.debug("MainWindowController: didDecodeRestorableState: \(state)")
		restoreState(from: state)
	}

	func windowWillClose(_ notification: Notification) {
		Self.logger.debug("MainWindowController: windowWillClose")
		detailViewController?.stopMediaPlayback()
		appDelegate.removeMainWindow(self)
	}
}

// MARK: - SidebarDelegate

extension MainWindowController: SidebarDelegate {

	func sidebarSelectionDidChange(_: SidebarViewController, selectedObjects: [AnyObject]?) {
		// Don’t update the timeline if it already has those objects.
		let representedObjectsAreTheSame = timelineContainerViewController?.regularTimelineViewControllerHasRepresentedObjects(selectedObjects) ?? false
		if !representedObjectsAreTheSame {
			timelineContainerViewController?.setRepresentedObjects(selectedObjects, mode: .regular)
			forceSearchToEnd()
		}
		updateWindowTitle()
		detailPaneViewController?.updateJobPanel()
		NotificationCenter.default.post(name: .InspectableObjectsDidChange, object: nil)
	}

	func unreadCount(for representedObject: AnyObject) -> Int {
		guard let timelineViewController = regularTimelineViewController else {
			return 0
		}
		guard timelineViewController.representsThisObjectOnly(representedObject) else {
			return 0
		}
		return timelineViewController.unreadCount
	}

	func sidebarInvalidatedRestorationState(_: SidebarViewController) {
		Self.logger.debug("MainWindowController: sidebarInvalidatedRestorationState")
		invalidateRestorableState()
	}
}

// MARK: - TimelineContainerViewControllerDelegate

extension MainWindowController: TimelineContainerViewControllerDelegate {

	func timelineSelectionDidChange(_: TimelineContainerViewController, articles: [Article]?, mode: TimelineSourceMode) {
		activityManager.invalidateReading()

		articleExtractor?.cancel()
		articleExtractor = nil
		isShowingExtractedArticle = false
		makeToolbarValidate()

		let detailState: DetailState
		if let articles = articles {
			if articles.count == 1 {
				activityManager.reading(feed: nil, article: articles.first)
				if articles.first?.feed?.readerViewAlwaysEnabled == true {
					detailState = .loading
					startArticleExtractorForCurrentLink()
				} else {
					detailState = .article(articles.first!, restoreArticleWindowScrollY)
					restoreArticleWindowScrollY = nil
				}
			} else {
				detailState = .multipleSelection
			}
		} else {
			detailState = .noSelection
		}

		detailViewController?.setState(detailState, mode: mode)
		updateStatusBarLink()

		let selectedArticle = (articles?.count == 1) ? articles?.first : nil
		aiViewController?.article = selectedArticle
		detailPaneViewController?.article = selectedArticle
	}

	func timelineRequestedFeedSelection(_: TimelineContainerViewController, feed: Feed) {
		sidebarViewController?.selectFeed(feed)
	}

	func timelineInvalidatedRestorationState(_: TimelineContainerViewController) {
		invalidateRestorableState()
	}

}

// MARK: - NSSearchFieldDelegate

extension MainWindowController: NSSearchFieldDelegate {

	func searchFieldDidStartSearching(_ sender: NSSearchField) {
		startSearchingIfNeeded()
	}

	func searchFieldDidEndSearching(_ sender: NSSearchField) {
		stopSearchingIfNeeded()
	}

	@IBAction func runSearch(_ sender: NSSearchField) {
		if sender.stringValue == "" {
			return
		}
		startSearchingIfNeeded()
		handleSearchFieldTextChange(sender)
	}

	private func handleSearchFieldTextChange(_ searchField: NSSearchField) {
		let s = searchField.stringValue
		if s == searchString {
			return
		}
		searchString = s
		updateSmartFeed()
	}

	func updateSmartFeed() {
		guard timelineSourceMode == .search, let searchString = searchString else {
			return
		}
		if searchString == lastSentSearchString {
			return
		}
		lastSentSearchString = searchString
		let smartFeed = SmartFeed(delegate: SearchFeedDelegate(searchString: searchString))
		timelineContainerViewController?.setRepresentedObjects([smartFeed], mode: .search)
		searchSmartFeed = smartFeed
		updateWindowTitle()
	}

	func forceSearchToEnd() {
		timelineSourceMode = .regular
		searchString = nil
		lastSentSearchString = nil
		if let searchField = currentSearchField {
			searchField.stringValue = ""
		}
		updateWindowTitle()
	}

	private func startSearchingIfNeeded() {
		timelineSourceMode = .search
		updateWindowTitle()
	}

	private func stopSearchingIfNeeded() {
		searchString = nil
		lastSentSearchString = nil
		timelineSourceMode = .regular
		timelineContainerViewController?.setRepresentedObjects(nil, mode: .search)
		updateWindowTitle()
	}
}

// MARK: - ArticleExtractorDelegate

extension MainWindowController: ArticleExtractorDelegate {

	func articleExtractionDidFail(with: Error) {
		makeToolbarValidate()
	}

	func articleExtractionDidComplete(extractedArticle: ExtractedArticle) {
		if let article = oneSelectedArticle, articleExtractor?.state != .cancelled {
			isShowingExtractedArticle = true
			let detailState = DetailState.extracted(article, extractedArticle, restoreArticleWindowScrollY)
			restoreArticleWindowScrollY = nil
			detailViewController?.setState(detailState, mode: timelineSourceMode)
			makeToolbarValidate()
		}
	}

}

// MARK: - Scripting Access

/*
    the ScriptingMainWindowController protocol exposes a narrow set of accessors with
    internal visibility which are very similar to some private vars.

    These would be unnecessary if the similar accessors were marked internal rather than private,
    but for now, we'll keep the stratification of visibility
*/

extension MainWindowController: ScriptingMainWindowController {
    var scriptingCurrentArticle: Article? {
        oneSelectedArticle
    }

    var scriptingSelectedArticles: [Article] {
        selectedArticles ?? []
    }

    var scriptingSelectedFeeds: [Feed] {
        selectedObjectsInSidebar()?.compactMap { $0 as? Feed } ?? []
    }
}

// MARK: - DetailViewControllerDelegate

extension MainWindowController: DetailViewControllerDelegate {

	func detailViewController(_ detailViewController: DetailViewController, mouseoverLinkDidChange link: String?) {
		mouseoverLink = link
	}
}

// MARK: - MainWindowStatusBarViewDelegate

extension MainWindowController: MainWindowStatusBarViewDelegate {

	func statusBarViewGearMenu(_ statusBarView: MainWindowStatusBarView) -> NSMenu? {
		guard let menu = sidebarViewController?.statusBarMenu() else {
			return nil
		}

		var index = 0
		if AccountManager.shared.canRefresh {
			menu.insertItem(withTitle: NSLocalizedString("Refresh", comment: "Refresh"), action: #selector(AppDelegate.refreshAll(_:)), keyEquivalent: "", at: index)
			index += 1
		}

		let isSidebarHidden = sidebarSplitViewItem?.isCollapsed ?? false
		let sidebarTitle = isSidebarHidden ? NSLocalizedString("Show Sidebar", comment: "Command") : NSLocalizedString("Hide Sidebar", comment: "Command")
		menu.insertItem(withTitle: sidebarTitle, action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "", at: index)
		index += 1

		let aiTitle = isAIPaneVisible ? "隐藏 AI 对话栏" : "显示 AI 对话栏"
		let aiItem = NSMenuItem(title: aiTitle, action: #selector(toggleAIPane(_:)), keyEquivalent: "")
		aiItem.target = self
		menu.insertItem(aiItem, at: index)
		index += 1

		menu.insertItem(NSMenuItem.separator(), at: index)

		return menu
	}

	func statusBarView(_ statusBarView: MainWindowStatusBarView, moveSidebarDividerTo position: CGFloat) {
		guard let splitView = splitViewController?.splitView else {
			return
		}
		let positionInWindow = statusBarView.convert(NSPoint(x: position, y: 0), to: nil)
		let positionInSplitView = splitView.convert(positionInWindow, from: nil)
		splitView.setPosition(positionInSplitView.x, ofDividerAt: 0)
	}
}

// MARK: - NSToolbarDelegate

extension NSToolbarItem.Identifier {
	static let newFeed = NSToolbarItem.Identifier("newFeed")
	static let newFolder = NSToolbarItem.Identifier("newFolder")
	static let refresh = NSToolbarItem.Identifier("refresh")
	static let newSidebarItemMenu = NSToolbarItem.Identifier("newSidebarItemMenu")
	static let timelineTrackingSeparator = NSToolbarItem.Identifier("timelineTrackingSeparator")
	static let search = NSToolbarItem.Identifier("search")
	static let markAllAsRead = NSToolbarItem.Identifier("markAllAsRead")
	static let toggleReadArticlesFilter = NSToolbarItem.Identifier("toggleReadArticlesFilter")
	static let nextUnread = NSToolbarItem.Identifier("nextUnread")
	static let markRead = NSToolbarItem.Identifier("markRead")
	static let markStar = NSToolbarItem.Identifier("markStar")
	static let readerView = NSToolbarItem.Identifier("readerView")
	static let openInBrowser = NSToolbarItem.Identifier("openInBrowser")
	static let share = NSToolbarItem.Identifier("share")
	static let articleThemeMenu = NSToolbarItem.Identifier("articleThemeMenu")
	static let cleanUp = NSToolbarItem.Identifier("cleanUp")
	static let aiChat = NSToolbarItem.Identifier("aiChat")
}

extension MainWindowController: NSToolbarDelegate {

	func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

		switch itemIdentifier {

		case .refresh:
			let title = NSLocalizedString("Refresh", comment: "Refresh")
			return buildToolbarButton(.refresh, title, Assets.Images.refresh, "refreshAll:")

		case .newSidebarItemMenu:
			let toolbarItem = NSMenuToolbarItem(itemIdentifier: .newSidebarItemMenu)
			toolbarItem.image = Assets.Images.addNewSidebarItem
			let description = NSLocalizedString("Add Item", comment: "Add Item")
			toolbarItem.toolTip = description
			toolbarItem.label = description
			toolbarItem.menu = buildNewSidebarItemMenu()
			return toolbarItem

		case .markAllAsRead:
			let title = NSLocalizedString("Mark All as Read", comment: "Command")
			return buildToolbarButton(.markAllAsRead, title, Assets.Images.markAllAsRead, "markAllAsRead:")

		case .toggleReadArticlesFilter:
			let title = NSLocalizedString("Read Articles Filter", comment: "Read Articles Filter")
			return buildToolbarButton(.toggleReadArticlesFilter, title, Assets.Images.filterInactive, "toggleReadArticlesFilter:")

		case .timelineTrackingSeparator:
			// Only the standard layout has a vertical divider between the timeline and the article view.
			// Column layout gets a hidden placeholder so the identifier stays in the saved configuration
			// and the separator returns when the layout does — one toolbar, one customization.
			guard timelineLayout == .standard, let splitView = splitViewController?.splitView else {
				let placeholder = NSToolbarItem(itemIdentifier: .timelineTrackingSeparator)
				placeholder.isHidden = true
				// Hidden in the toolbar, but the customization palette still lists it, so it needs a name and an image there.
				let description = NSLocalizedString("Timeline Separator", comment: "Toolbar item")
				placeholder.label = description
				placeholder.paletteLabel = description
				placeholder.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: description)
				return placeholder
			}
			return NSTrackingSeparatorToolbarItem(identifier: .timelineTrackingSeparator, splitView: splitView, dividerIndex: 1)

		case .markRead:
			let title = NSLocalizedString("Mark Read", comment: "command")
			return buildToolbarButton(.markRead, title, Assets.Images.readClosed, "toggleRead:")

		case .markStar:
			let title = NSLocalizedString("Star", comment: "Star")
			return buildToolbarButton(.markStar, title, Assets.Images.starOpen, "toggleStarred:")

		case .nextUnread:
			let title = NSLocalizedString("Next Unread", comment: "Next Unread")
			return buildToolbarButton(.nextUnread, title, Assets.Images.nextUnread, "nextUnread:")

		case .readerView:
			let toolbarItem = RSToolbarItem(itemIdentifier: .readerView)
			toolbarItem.autovalidates = true
			let description = NSLocalizedString("Reader View", comment: "Reader View")
			toolbarItem.toolTip = description
			toolbarItem.label = description
			let button = ArticleExtractorButton()
			button.action = #selector(toggleArticleExtractor(_:))
			toolbarItem.view = button
			toolbarItem.menuFormRepresentation = NSMenuItem(title: description, action: #selector(toggleArticleExtractor(_:)), keyEquivalent: "")
			return toolbarItem

		case .share:
			let title = NSLocalizedString("Share", comment: "Share button")
			return buildToolbarButton(.share, title, Assets.Images.share, "toolbarShowShareMenu:")

		case .openInBrowser:
			let title = NSLocalizedString("Open in Browser", comment: "Command")
			return buildToolbarButton(.openInBrowser, title, Assets.Images.openInBrowser, "openArticleInBrowser:")

		case .articleThemeMenu:
			// Built per toolbar: a toolbar item belongs to one toolbar, and the toolbar is rebuilt on a layout switch.
			let toolbarItem = NSMenuToolbarItem(itemIdentifier: .articleThemeMenu)
			toolbarItem.image = Assets.Images.articleTheme
			let description = NSLocalizedString("Article Theme", comment: "Article Theme")
			toolbarItem.toolTip = description
			toolbarItem.label = description
			toolbarItem.menu = ArticleThemesManager.shared.makeArticleThemeMenu()
			return toolbarItem

		case .search:
			let toolbarItem = NSSearchToolbarItem(itemIdentifier: .search)
			let description = NSLocalizedString("Search", comment: "Search")
			toolbarItem.toolTip = description
			toolbarItem.label = description
			return toolbarItem

		case .cleanUp:
			let title = NSLocalizedString("Clean Up", comment: "Clean Up button")
			return buildToolbarButton(.cleanUp, title, Assets.Images.cleanUp, "cleanUp:")

		case .aiChat:
			let title = "AI 对话栏"
			let image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: title) ?? NSImage(size: NSSize(width: 16, height: 16))
			return buildToolbarButton(.aiChat, title, image, "toggleAIPane:")

		default:
			break
		}

		return nil
	}

	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[
			NSToolbarItem.Identifier.toggleSidebar,
			.refresh,
			.newSidebarItemMenu,
			.sidebarTrackingSeparator,
			.markAllAsRead,
			.toggleReadArticlesFilter,
			.timelineTrackingSeparator,
			.flexibleSpace,
			.nextUnread,
			.markRead,
			.markStar,
			.readerView,
			.openInBrowser,
			.share,
			.articleThemeMenu,
			.search,
			.cleanUp,
			.aiChat
		]
	}

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[
			NSToolbarItem.Identifier.toggleSidebar,
			.flexibleSpace,
			.refresh,
			.newSidebarItemMenu,
			.sidebarTrackingSeparator,
			.markAllAsRead,
			.toggleReadArticlesFilter,
			.timelineTrackingSeparator,
			.markRead,
			.markStar,
			.nextUnread,
			.readerView,
			.share,
			.openInBrowser,
			.flexibleSpace,
			.aiChat,
			.search
		]
	}

	func toolbarWillAddItem(_ notification: Notification) {
		guard let item = notification.userInfo?["item"] as? NSToolbarItem else {
			return
		}

		if item.itemIdentifier == .share, let button = item.view as? NSButton {
			// The share button should send its action on mouse down, not mouse up.
			button.sendAction(on: .leftMouseDown)
		}

		if item.itemIdentifier == .search, let searchItem = item as? NSSearchToolbarItem {
			searchItem.searchField.delegate = self
			searchItem.searchField.target = self
			searchItem.searchField.action = #selector(runSearch(_:))
			currentSearchField = searchItem.searchField
		}
	}

	func toolbarDidRemoveItem(_ notification: Notification) {
		guard let item = notification.userInfo?["item"] as? NSToolbarItem else {
			return
		}

		if item.itemIdentifier == .search, let searchItem = item as? NSSearchToolbarItem {
			searchItem.searchField.delegate = nil
			searchItem.searchField.target = nil
			searchItem.searchField.action = nil
			currentSearchField = nil
		}
	}
}

// MARK: - AI Pane

extension MainWindowController {

	/// Closes the AI pane when it is showing. Returns true when it did.
	func closeAIPaneIfVisible() -> Bool {
		guard isAIPaneVisible else {
			return false
		}
		setAIPaneVisible(false, focus: false)
		return true
	}
}

// MARK: - Keyboard

extension MainWindowController {

	/// Clears the timeline’s article selection on Escape, so the detail pane
	/// goes back to the no-selection state and the task panel shows again.
	/// Returns false when the event belongs to something else, which lets it
	/// travel on to the page or the field that owns it.
	func closeSelectedArticleOnEscape(from view: NSView) -> Bool {
		let window = view.window
		let firstResponder = window?.firstResponder
		let policy = EscapeArticleClosePolicy(
			hasSelectedArticle: oneSelectedArticle != nil,
			isTextInputFirstResponder: firstResponder is NSTextView || firstResponder is NSTextField,
			hasModalWindowOrSheet: window?.attachedSheet != nil || NSApp.modalWindow != nil,
			isArticleBodyFirstResponder: view is DetailWebView
		)
		guard policy.shouldCloseSelectedArticle, let timeline = currentTimelineViewController else {
			return false
		}

		timeline.tableView.deselectAll(nil)
		makeTimelineViewFirstResponder()
		return true
	}
}

// MARK: - Private

private extension MainWindowController {

	// MARK: - Layout

	/// Builds the split views for `layout` around the existing panes, replacing any current ones.
	/// Selection, loaded articles, and the article view’s web view all survive, since the panes are reparented, not recreated.
	func installSplitViewController(for layout: TimelineLayout) {
		guard let window, let sidebarViewController, let timelineContainerViewController, let detailPaneViewController, let aiViewController else {
			return
		}

		rememberCurrentLayoutGeometry()
		let savedFrame = window.frame
		let isSidebarHidden = sidebarSplitViewItem?.isCollapsed ?? false
		let firstResponderView = window.firstResponder as? NSView

		// The toolbar lives for the window’s life so the user’s customization is one thing. Only its tracking separators
		// depend on the split views: they come out before the swap and go back in the same positions after,
		// which also lets the timeline separator change kind for the new layout. The toolbar is hidden meanwhile —
		// AppKit lays out its title area during the swap and reports conflicting constraints without the separators.
		let trackingSeparators = removeTrackingSeparatorsFromToolbar()
		let isToolbarVisible = window.toolbar?.isVisible ?? true
		window.toolbar?.isVisible = false

		detachSplitViewControllers()

		let newSplitViewController: NSSplitViewController
		switch layout {
		case .standard:
			newSplitViewController = makeStandardSplitViewController(sidebar: sidebarViewController, timeline: timelineContainerViewController, detail: detailPaneViewController, ai: aiViewController)
		case .column:
			let columnLayoutSplitViewControllers = makeColumnLayoutSplitViewControllers(sidebar: sidebarViewController, timeline: timelineContainerViewController, detail: detailPaneViewController, ai: aiViewController)
			newSplitViewController = columnLayoutSplitViewControllers.split
			contentSplitViewController = columnLayoutSplitViewControllers.content
		}
		splitViewController = newSplitViewController
		timelineLayout = layout
		if window.contentViewController !== mainWindowContentViewController {
			window.contentViewController = mainWindowContentViewController
		}
		mainWindowContentViewController.splitViewController = newSplitViewController
		if window.frame != savedFrame && !window.styleMask.contains(.fullScreen) {
			window.setFrame(savedFrame, display: false)
		}

		if let toolbar = window.toolbar {
			for (identifier, index) in trackingSeparators {
				toolbar.insertItem(withItemIdentifier: identifier, at: index)
			}
			toolbar.isVisible = isToolbarVisible
		} else {
			window.toolbar = makeToolbar()
		}

		window.contentView?.layoutSubtreeIfNeeded()
		applyRememberedGeometry()
		if isAIPaneVisible {
			applyAIPaneWidth()
		}
		sidebarSplitViewItem?.isCollapsed = isSidebarHidden

		if let firstResponderView, firstResponderView.window === window {
			window.makeFirstResponder(firstResponderView)
		} else {
			currentTimelineViewController?.focus()
		}
		window.recalculateKeyViewLoop()
		observeSplitViewForStatusBar()
		invalidateRestorableState()
	}

	/// Removes the sidebar and timeline tracking separators, returning their identifiers and positions in ascending order.
	func removeTrackingSeparatorsFromToolbar() -> [(NSToolbarItem.Identifier, Int)] {
		guard let toolbar = window?.toolbar else {
			return []
		}
		let separatorIdentifiers: Set<NSToolbarItem.Identifier> = [.sidebarTrackingSeparator, .timelineTrackingSeparator]
		let separators = toolbar.items.enumerated().filter { separatorIdentifiers.contains($0.element.itemIdentifier) }.map { ($0.element.itemIdentifier, $0.offset) }
		for (_, index) in separators.reversed() {
			toolbar.removeItem(at: index)
		}
		return separators
	}

	func detachSplitViewControllers() {
		// NSSplitViewItem requires a parentless view controller, so remove the panes from the old split views first.
		if let contentSplitViewController {
			for item in contentSplitViewController.splitViewItems.reversed() {
				contentSplitViewController.removeSplitViewItem(item)
			}
		}
		if let splitViewController {
			for item in splitViewController.splitViewItems.reversed() {
				splitViewController.removeSplitViewItem(item)
			}
		}
		contentSplitViewController = nil
		splitViewController = nil
		aiSplitViewItem = nil
	}

	func makeStandardSplitViewController(sidebar: SidebarViewController, timeline: TimelineContainerViewController, detail: AIDetailPaneViewController, ai: AIChatViewController) -> NSSplitViewController {
		let splitViewController = makeEmptySplitViewController(isVertical: true)

		let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
		sidebarItem.holdingPriority = NSLayoutConstraint.Priority(Self.sidebarHoldingPriority)

		let timelineItem = NSSplitViewItem(contentListWithViewController: timeline)
		timelineItem.holdingPriority = NSLayoutConstraint.Priority(Self.timelineHoldingPriority)
		if #available(macOS 26.0, *) {
			timelineItem.automaticallyAdjustsSafeAreaInsets = true
		}

		let detailItem = NSSplitViewItem(viewController: detail)
		detailItem.minimumThickness = CGFloat(Self.detailViewMinimumWidth)
		if #unavailable(macOS 26.0) {
			detailItem.titlebarSeparatorStyle = .line
		}

		var splitViewItems = [sidebarItem, timelineItem, detailItem]
		if isAIPaneVisible {
			let aiItem = makeAIPaneSplitViewItem(viewController: ai)
			aiSplitViewItem = aiItem
			splitViewItems.append(aiItem)
		}

		splitViewController.splitViewItems = splitViewItems
		sidebar.splitViewItem = sidebarItem
		return splitViewController
	}

	/// Returns the outer split (sidebar and content) and the content split (timeline above detail) it contains.
	func makeColumnLayoutSplitViewControllers(sidebar: SidebarViewController, timeline: TimelineContainerViewController, detail: AIDetailPaneViewController, ai: AIChatViewController) -> (split: NSSplitViewController, content: NSSplitViewController) {
		let contentSplitViewController = makeEmptySplitViewController(isVertical: false, splitView: ColumnLayoutSplitView())
		contentSplitViewController.splitView.dividerStyle = .paneSplitter

		let timelineItem = NSSplitViewItem(viewController: timeline)
		timelineItem.holdingPriority = NSLayoutConstraint.Priority(Self.timelineHoldingPriority)
		timelineItem.minimumThickness = Self.timelineMinimumHeight
		timelineItem.canCollapse = false

		let detailItem = NSSplitViewItem(viewController: detail)
		detailItem.minimumThickness = Self.detailViewMinimumHeight
		detailItem.canCollapse = false

		contentSplitViewController.splitViewItems = [timelineItem, detailItem]

		let splitViewController = makeEmptySplitViewController(isVertical: true)

		let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
		sidebarItem.holdingPriority = NSLayoutConstraint.Priority(Self.sidebarHoldingPriority)

		let contentItem = NSSplitViewItem(viewController: contentSplitViewController)
		if #available(macOS 26.0, *) {
			contentItem.automaticallyAdjustsSafeAreaInsets = true
		} else {
			contentItem.titlebarSeparatorStyle = .line
		}

		var splitViewItems = [sidebarItem, contentItem]
		if isAIPaneVisible {
			let aiItem = makeAIPaneSplitViewItem(viewController: ai)
			aiSplitViewItem = aiItem
			splitViewItems.append(aiItem)
		}

		splitViewController.splitViewItems = splitViewItems
		sidebar.splitViewItem = sidebarItem
		return (splitViewController, contentSplitViewController)
	}

	func makeAIPaneSplitViewItem(viewController: AIChatViewController) -> NSSplitViewItem {
		let item = NSSplitViewItem(viewController: viewController)
		// Start at the remembered width: a required minimum is the one constraint
		// the split view controller honors when a pane is added to a live split view.
		item.minimumThickness = CGFloat(max(rememberedAIPaneWidth, Int(Self.aiPaneMinimumWidth)))
		item.canCollapse = false
		item.holdingPriority = NSLayoutConstraint.Priority(Self.aiPaneHoldingPriority)
		if #unavailable(macOS 26.0) {
			item.titlebarSeparatorStyle = .line
		}
		return item
	}

	func makeEmptySplitViewController(isVertical: Bool, splitView: NSSplitView = MainWindowSplitView()) -> NSSplitViewController {
		let splitViewController = NSSplitViewController()
		splitViewController.splitView = splitView
		splitViewController.splitView.isVertical = isVertical
		splitViewController.splitView.dividerStyle = .thin
		splitViewController.splitView.wantsLayer = true
		return splitViewController
	}

	func makeToolbar() -> NSToolbar {
		let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
		toolbar.allowsUserCustomization = true
		toolbar.autosavesConfiguration = true
		toolbar.displayMode = .iconOnly
		toolbar.delegate = self
		return toolbar
	}

	var currentTimelineViewController: TimelineViewController? {
		return timelineContainerViewController?.currentTimelineViewController
	}

	var regularTimelineViewController: TimelineViewController? {
		return timelineContainerViewController?.regularTimelineViewController
	}

	var sidebarSplitViewItem: NSSplitViewItem? {
		splitViewController?.splitViewItems.first
	}

	var selectedArticles: [Article]? {
		return currentTimelineViewController?.selectedArticles
	}

	var oneSelectedArticle: Article? {
		if let articles = selectedArticles {
			return articles.count == 1 ? articles[0] : nil
		}
		return nil
	}

	var currentLink: String? {
		return oneSelectedArticle?.preferredLink
	}

	// MARK: - State Restoration

	func savableState() -> MainWindowState {
		let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
		let isSidebarHidden = sidebarSplitViewItem?.isCollapsed ?? false

		rememberCurrentLayoutGeometry()

		return MainWindowState(isFullScreen: isFullScreen,
							   splitViewWidths: rememberedStandardLayoutWidths,
							   columnLayoutTimelineHeight: rememberedColumnLayoutTimelineHeight,
							   isSidebarHidden: isSidebarHidden,
							   isAIPaneVisible: isAIPaneVisible,
							   aiPaneWidth: rememberedAIPaneWidth,
							   sidebarWindowState: sidebarViewController?.windowState,
							   timelineWindowState: timelineContainerViewController?.windowState,
							   detailWindowState: detailViewController?.windowState)
	}

	/// Reads the live split view positions into the remembered geometry for the current layout.
	/// The sidebar is shared by both layouts, so its width is always refreshed.
	func rememberCurrentLayoutGeometry() {
		guard let splitView = splitViewController?.splitView, let window, let sidebarView = splitView.arrangedSubviews.first else {
			return
		}
		let dividerThickness = splitView.dividerThickness
		let isSidebarHidden = sidebarSplitViewItem?.isCollapsed ?? false
		let visibleSidebarWidth = isSidebarHidden ? 0.0 : sidebarView.frame.width
		// While collapsed, keep the last visible width so a rebuilt split view can reopen the sidebar at that width.
		let previousSidebarWidth = rememberedStandardLayoutWidths.count == 3 ? rememberedStandardLayoutWidths[0] : 0
		let sidebarWidth = isSidebarHidden ? previousSidebarWidth : Int(floor(visibleSidebarWidth))

		let aiWidth: CGFloat
		if isAIPaneVisible, let aiView = splitView.arrangedSubviews.last {
			aiWidth = aiView.frame.width
			rememberedAIPaneWidth = Int(floor(aiWidth))
		} else {
			aiWidth = 0
		}

		switch timelineLayout {
		case .standard:
			let expectedPaneCount = isAIPaneVisible ? 4 : 3
			guard splitView.arrangedSubviews.count == expectedPaneCount else {
				return
			}
			let detailWidth = splitView.arrangedSubviews[2].frame.width
			// Starting with macOS 26, timelineWidth has to be calculated —
			// because its width is greater than its apparent width,
			// so that things can slide under the sidebar.
			let dividerCount: CGFloat = CGFloat(splitView.arrangedSubviews.count - 1) - (isSidebarHidden ? 1.0 : 0.0)
			let timelineWidth = window.frame.width - (visibleSidebarWidth + detailWidth + aiWidth + (dividerThickness * dividerCount))
			rememberedStandardLayoutWidths = [sidebarWidth, Int(floor(timelineWidth)), Int(floor(detailWidth))]

		case .column:
			if rememberedStandardLayoutWidths.count == 3 {
				rememberedStandardLayoutWidths[0] = sidebarWidth
			} else {
				rememberedStandardLayoutWidths = [sidebarWidth, 0, 0]
			}
			if let timelineView = contentSplitViewController?.splitView.arrangedSubviews.first {
				rememberedColumnLayoutTimelineHeight = Int(floor(timelineView.frame.height))
			}
		}
	}

	func applyRememberedGeometry() {
		guard let splitView = splitViewController?.splitView else {
			return
		}
		let widths = rememberedStandardLayoutWidths

		switch timelineLayout {
		case .standard:
			guard widths.count == 3 else {
				return
			}
			let sidebarWidth = CGFloat(widths[0])
			let timelineWidth = CGFloat(widths[1])
			// The sidebar is positioned expanded here and collapsed by the caller afterward. A zero sidebar width
			// comes from state saved before the collapsed width was kept (7.1.x) — keep the default width.
			if sidebarWidth > 0 {
				splitView.setPosition(sidebarWidth, ofDividerAt: 0)
			}
			// A zero timeline width means the standard layout has never been laid out — leave it to the holding priorities.
			if timelineWidth > 0 {
				let secondDividerPosition = sidebarWidth > 0 ? sidebarWidth + splitView.dividerThickness + timelineWidth : timelineWidth
				splitView.setPosition(secondDividerPosition, ofDividerAt: 1)
			}

		case .column:
			if widths.count == 3 && widths[0] > 0 {
				splitView.setPosition(CGFloat(widths[0]), ofDividerAt: 0)
			}
			guard let contentSplitView = contentSplitViewController?.splitView else {
				return
			}
			let timelineHeight: CGFloat
			if rememberedColumnLayoutTimelineHeight > 0 {
				timelineHeight = CGFloat(rememberedColumnLayoutTimelineHeight)
			} else {
				timelineHeight = floor(contentSplitView.bounds.height * Self.defaultColumnLayoutTimelineHeightFraction)
			}
			contentSplitView.setPosition(timelineHeight, ofDividerAt: 0)
		}
	}

	func applyAIPaneWidth() {
		guard isAIPaneVisible, let splitView = splitViewController?.splitView else {
			return
		}
		let paneCount = splitView.arrangedSubviews.count
		guard paneCount >= 2 else {
			return
		}
		splitView.layoutSubtreeIfNeeded()
		let width = CGFloat(max(rememberedAIPaneWidth, Int(Self.aiPaneMinimumWidth)))
		let position = splitView.bounds.width - width
		guard position > 0 else {
			return
		}
		splitView.setPosition(position, ofDividerAt: paneCount - 2)
	}

	func setAIPaneVisible(_ visible: Bool, focus: Bool) {
		guard visible != isAIPaneVisible else {
			if visible && focus {
				aiViewController?.focusInput()
			}
			return
		}
		guard let splitViewController, let aiViewController else {
			return
		}

		if visible {
			ensureWindowWideEnoughForAIPane()
			let aiItem = makeAIPaneSplitViewItem(viewController: aiViewController)
			isAIPaneVisible = true
			aiSplitViewItem = aiItem
			splitViewController.addSplitViewItem(aiItem)
			splitViewController.view.layoutSubtreeIfNeeded()
			applyAIPaneWidth()
			updateAIPaneArticle()
			if focus {
				aiViewController.focusInput()
			}
		} else {
			// Capture the width while the pane is still in the split view, so reopening
			// later restores the width the reader chose.
			rememberCurrentLayoutGeometry()
			let item = aiSplitViewItem
			isAIPaneVisible = false
			aiSplitViewItem = nil
			if let item {
				splitViewController.removeSplitViewItem(item)
			}
		}

		makeToolbarValidate()
		invalidateRestorableState()
		window?.recalculateKeyViewLoop()
	}

	func ensureWindowWideEnoughForAIPane() {
		guard let window, let splitView = splitViewController?.splitView else {
			return
		}
		let isSidebarHidden = sidebarSplitViewItem?.isCollapsed ?? false
		let sidebarWidth = isSidebarHidden ? 0.0 : (splitView.arrangedSubviews.first?.frame.width ?? 0)
		let timelineMinimumWidth: CGFloat = 200
		let timelineWidth = splitView.arrangedSubviews.count > 1 ? splitView.arrangedSubviews[1].frame.width : timelineMinimumWidth
		// Grow for the remembered width, not just the minimum, so reopening the pane
		// keeps the width the reader chose instead of squeezing it to its minimum.
		let requestedAIWidth = CGFloat(max(rememberedAIPaneWidth, Int(Self.aiPaneMinimumWidth)))
		let requiredWidth = sidebarWidth + max(timelineWidth, timelineMinimumWidth) + CGFloat(Self.detailViewMinimumWidth) + requestedAIWidth + (3 * splitView.dividerThickness) + 16
		guard window.frame.width < requiredWidth else {
			return
		}
		let maximumWidth = window.screen?.visibleFrame.width ?? requiredWidth
		var frame = window.frame
		frame.size.width = min(requiredWidth, maximumWidth)
		window.setFrame(frame, display: true)
	}

	func updateAIPaneArticle() {
		let article = oneSelectedArticle
		aiViewController?.article = article
		detailPaneViewController?.article = article
	}

	func restoreState(from state: MainWindowState) {
		if state.isFullScreen {
			// Defer the toggle — during launch the window isn't on screen yet,
			// and AppKit ignores toggleFullScreen for windows not yet on screen.
			Task { @MainActor in
				guard let window = self.window, !window.styleMask.contains(.fullScreen) else {
					return
				}
				window.toggleFullScreen(nil)
			}
		}
		restoreSplitViewState(from: state)

		sidebarViewController?.restoreState(from: state.sidebarWindowState)

		timelineContainerViewController?.restoreState(from: state.timelineWindowState)
		restoreArticleWindowScrollY = state.detailWindowState?.windowScrollY

		let isShowingExtractedArticle = state.detailWindowState?.isShowingExtractedArticle ?? false
		if isShowingExtractedArticle {
			startArticleExtractorForCurrentLink()
		}

		updateAIPaneArticle()
	}

	/// Restore state using pre-secure-state-restoration data.
	///
	/// It’s up to the caller to call this only when:
	/// 1. Legacy state exists, and
	/// 2. Secure state data does not exist.
	///
	/// TODO: delete this for NetNewsWire 7.
	func restoreLegacyState(from state: [AnyHashable: Any]) {
		if let fullScreen = state[UserInfoKey.windowFullScreenState] as? Bool, fullScreen {
			window?.toggleFullScreen(self)
		}
		restoreLegacySplitViewState(from: state)

		sidebarViewController?.restoreLegacyState(from: state)

		let articleWindowScrollY = state[UserInfoKey.articleWindowScrollY] as? CGFloat
		restoreArticleWindowScrollY = articleWindowScrollY
		timelineContainerViewController?.restoreLegacyState(from: state)

		let isShowingExtractedArticle = state[UserInfoKey.isShowingExtractedArticle] as? Bool ?? false
		if isShowingExtractedArticle {
			restoreArticleWindowScrollY = articleWindowScrollY
			startArticleExtractorForCurrentLink()
		}

		updateAIPaneArticle()
	}

	// MARK: - Command Validation

	func canCopyArticleURL() -> Bool {
		guard let selectedArticles else {
			return false
		}

		for article in selectedArticles {
			if article.preferredLink != nil {
				return true
			}
		}
		return false
	}

	func canCopyExternalURL() -> Bool {
		guard let selectedArticles else {
			return false
		}

		for article in selectedArticles {
			if article.externalLink != nil {
				return true
			}
		}
		return false
	}

	func canGoToNextUnread(wrappingToTop wrapping: Bool = false) -> Bool {

		guard let timelineViewController = currentTimelineViewController, let sidebarViewController = sidebarViewController else {
			return false
		}

		// When the only unread article in the account is the one already selected, Next Unread has nowhere to go.
		// This state persists on Mac when the selected article is marked read on selection and then manually marked unread again.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5008>
		if AccountManager.shared.unreadCount == 1, timelineViewController.selectedArticles.count == 1, let article = timelineViewController.selectedArticles.first, !article.status.read {
			return false
		}

		// TODO: handle search mode
		return timelineViewController.canGoToNextUnread(wrappingToTop: wrapping) || sidebarViewController.canGoToNextUnread(wrappingToTop: wrapping)
	}

	func canMarkAllAsRead() -> Bool {

		return currentTimelineViewController?.canMarkAllAsRead() ?? false
	}

	func validateToggleRead(_ item: NSValidatedUserInterfaceItem) -> Bool {

		let validationStatus = currentTimelineViewController?.markReadCommandStatus() ?? .canDoNothing
		let markingRead: Bool
		let result: Bool

		switch validationStatus {
		case .canMark:
			markingRead = true
			result = true
		case .canUnmark:
			markingRead = false
			result = true
		case .canDoNothing:
			markingRead = true
			result = false
		}

		let commandName = markingRead ? NSLocalizedString("Mark as Read", comment: "Command") : NSLocalizedString("Mark as Unread", comment: "Command")

		if let toolbarItem = item as? NSToolbarItem {
			toolbarItem.toolTip = commandName
			// Text Only toolbar mode shows the label and menu form representation, so they need to track state too.
			let shortName = markingRead ? NSLocalizedString("Mark Read", comment: "command") : NSLocalizedString("Mark Unread", comment: "command")
			toolbarItem.label = shortName
			toolbarItem.menuFormRepresentation?.title = shortName
		}

		if let menuItem = item as? NSMenuItem {
			menuItem.title = commandName
		}

		if let toolbarItem = item as? NSToolbarItem, let button = toolbarItem.view as? NSButton {
			button.image = markingRead ? Assets.Images.readClosed : Assets.Images.readOpen
		}

		return result
	}

	func validateToggleArticleExtractor(_ item: NSValidatedUserInterfaceItem) -> Bool {
		guard !AppDefaults.isDeveloperBuild else {
			return false
		}

		guard let toolbarItem = item as? NSToolbarItem, let toolbarButton = toolbarItem.view as? ArticleExtractorButton else {
			if let menuItem = item as? NSMenuItem {
				menuItem.state = isShowingExtractedArticle ? .on : .off
			}
			return currentLink != nil
		}

		if currentTimelineViewController?.selectedArticles.first?.feed != nil {
			toolbarButton.isEnabled = true
		}

		guard let state = articleExtractor?.state else {
			toolbarButton.buttonState = .off
			return currentLink != nil
		}

		switch state {
		case .processing:
			toolbarButton.buttonState = .animated
		case .failedToParse:
			toolbarButton.buttonState = .error
		case .ready, .cancelled, .complete:
			toolbarButton.buttonState = isShowingExtractedArticle ? .on : .off
		}

		return state != .processing
	}

	func canMarkAboveArticlesAsRead() -> Bool {
		return currentTimelineViewController?.canMarkAboveArticlesAsRead() ?? false
	}

	func canMarkBelowArticlesAsRead() -> Bool {
		return currentTimelineViewController?.canMarkBelowArticlesAsRead() ?? false
	}

	func canShowShareMenu() -> Bool {

		guard let selectedArticles = selectedArticles else {
			return false
		}
		return !selectedArticles.isEmpty
	}

	func validateToggleStarred(_ item: NSValidatedUserInterfaceItem) -> Bool {

		let validationStatus = currentTimelineViewController?.markStarredCommandStatus() ?? .canDoNothing
		let starring: Bool
		let result: Bool

		switch validationStatus {
		case .canMark:
			starring = true
			result = true
		case .canUnmark:
			starring = false
			result = true
		case .canDoNothing:
			starring = true
			result = false
		}

		let commandName = starring ? NSLocalizedString("Mark as Starred", comment: "Command") : NSLocalizedString("Mark as Unstarred", comment: "Command")

		if let toolbarItem = item as? NSToolbarItem {
			toolbarItem.toolTip = commandName
			// Text Only toolbar mode shows the label and menu form representation, so they need to track state too.
			let shortName = starring ? NSLocalizedString("Star", comment: "Star") : NSLocalizedString("Unstar", comment: "Unstar")
			toolbarItem.label = shortName
			toolbarItem.menuFormRepresentation?.title = shortName
		}

		if let menuItem = item as? NSMenuItem {
			menuItem.title = commandName
		}

		if let toolbarItem = item as? NSToolbarItem, let button = toolbarItem.view as? NSButton {
			button.image = starring ? Assets.Images.starOpen : Assets.Images.starClosed
		}

		return result
	}

	func validateCleanUp(_ item: NSValidatedUserInterfaceItem) -> Bool {
		return timelineContainerViewController?.isCleanUpAvailable ?? false
	}

	func validateToggleReadFeeds(_ item: NSValidatedUserInterfaceItem) -> Bool {
		guard let menuItem = item as? NSMenuItem else { return false }

		let showCommand = NSLocalizedString("Show Read Feeds", comment: "Command")
		let hideCommand = NSLocalizedString("Hide Read Feeds", comment: "Command")
		menuItem.title = sidebarViewController?.isReadFiltered ?? false ? showCommand : hideCommand
		return true
	}

	func validateSortArticlesByField(_ item: NSValidatedUserInterfaceItem) -> Bool {
		guard let sortParameters = timelineContainerViewController?.sortParameters, let menuItem = item as? NSMenuItem, let identifier = menuItem.identifier, let key = ArticleSortKey(rawValue: identifier.rawValue) else {
			return false
		}
		menuItem.state = sortParameters.key == key ? .on : .off
		return true
	}

	/// The direction items are worded for the current field: Oldest/Newest for date, A to Z for text, Ascending/Descending for flags.
	func validateSortDirection(_ item: NSValidatedUserInterfaceItem, direction: ComparisonResult) -> Bool {
		guard let sortParameters = timelineContainerViewController?.sortParameters, let menuItem = item as? NSMenuItem else {
			return false
		}
		menuItem.title = sortParameters.key.localizedDirectionTitle(ascending: direction == .orderedAscending)
		menuItem.state = sortParameters.direction == direction ? .on : .off
		return true
	}

	func validateToggleReadArticles(_ item: NSValidatedUserInterfaceItem) -> Bool {
		let showCommand = NSLocalizedString("Show Read Articles", comment: "Command")
		let hideCommand = NSLocalizedString("Hide Read Articles", comment: "Command")

		guard let isReadFiltered = timelineContainerViewController?.isReadFiltered else {
			(item as? NSMenuItem)?.title = hideCommand
			if let toolbarItem = item as? NSToolbarItem, let button = toolbarItem.view as? NSButton {
				toolbarItem.toolTip = hideCommand
				button.image = Assets.Images.filterInactive
			}
			return false
		}

		if isReadFiltered {
			(item as? NSMenuItem)?.title = showCommand
			if let toolbarItem = item as? NSToolbarItem, let button = toolbarItem.view as? NSButton {
				toolbarItem.toolTip = showCommand
				button.image = Assets.Images.filterActive
			}
		} else {
			(item as? NSMenuItem)?.title = hideCommand
			if let toolbarItem = item as? NSToolbarItem, let button = toolbarItem.view as? NSButton {
				toolbarItem.toolTip = hideCommand
				button.image = Assets.Images.filterInactive
			}
		}

		return true
	}

	// MARK: - Misc.

	func goToNextUnreadInTimeline(wrappingToTop wrapping: Bool) {

		guard let timelineViewController = currentTimelineViewController else {
			return
		}

		if timelineViewController.canGoToNextUnread(wrappingToTop: wrapping) {
			timelineViewController.goToNextUnread(wrappingToTop: wrapping)
			makeTimelineViewFirstResponder()
		}
	}

	func makeTimelineViewFirstResponder() {

		guard let window = window, let timelineViewController = currentTimelineViewController else {
			return
		}
		window.makeFirstResponderUnlessDescendantIsFirstResponder(timelineViewController.tableView)
	}

	func updateWindowTitle() {
		guard timelineSourceMode != .search else {
			let localizedLabel = NSLocalizedString("Search: %@", comment: "Search")
			window?.title = NSString.localizedStringWithFormat(localizedLabel as NSString, searchString ?? "") as String
			window?.subtitle = ""
			return
		}

		func setSubtitle(_ count: Int) {
			guard AppDefaults.unreadCountDisplay == .count else {
				window?.subtitle = ""
				return
			}
			let localizedLabel = NSLocalizedString("%d unread", comment: "Unread")
			let formattedLabel = NSString.localizedStringWithFormat(localizedLabel as NSString, count)
			window?.subtitle = formattedLabel as String
		}

		guard let selectedObjects = selectedObjectsInSidebar(), selectedObjects.count > 0 else {
			window?.title = appName
			setSubtitle(AccountManager.shared.unreadCount)
			return
		}

		guard selectedObjects.count == 1 else {
			window?.title = NSLocalizedString("Multiple", comment: "Multiple")
			let unreadCount = selectedObjects.reduce(0, { result, selectedObject in
				if let unreadCountProvider = selectedObject as? UnreadCountProvider {
					return result + unreadCountProvider.unreadCount
				} else {
					return result
				}
			})
			setSubtitle(unreadCount)

			return
		}

		if let displayNameProvider = currentFeedOrFolder as? DisplayNameProvider {
			window?.title = displayNameProvider.nameForDisplay
			if let unreadCountProvider = currentFeedOrFolder as? UnreadCountProvider {
				setSubtitle(unreadCountProvider.unreadCount)
			}
		}
	}

	func startArticleExtractorForCurrentLink() {
		if let link = currentLink, let extractor = ArticleExtractor(link, delegate: self) {
			extractor.process()
			articleExtractor = extractor
		}
	}

	/// Passes the reading area’s selected text to the AI pane as plain text.
	func fetchSelectedTextForAI(_ completion: @escaping (String?) -> Void) {
		detailViewController?.fetchSelectedHTML { html in
			guard let html, !html.isEmpty else {
				completion(nil)
				return
			}
			completion(Self.plainText(fromHTML: html))
		}
	}

	static func plainText(fromHTML html: String) -> String {
		guard let data = html.data(using: .utf8),
			  let attributedString = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else {
			let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
			return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	func restoreSplitViewState(from state: MainWindowState) {
		// AppKit’s restoration archive can lag behind the state we save ourselves
		// (it is encoded on its own schedule), so prefer the saved state for the
		// AI pane, which changes every time the reader drags its divider.
		let aiState = Self.savedUserDefaultsState() ?? state
		if state.splitViewWidths.count == 3 {
			rememberedStandardLayoutWidths = state.splitViewWidths
		}
		rememberedColumnLayoutTimelineHeight = state.columnLayoutTimelineHeight
		if aiState.aiPaneWidth > 0 {
			rememberedAIPaneWidth = aiState.aiPaneWidth
		}
		applyRememberedGeometry()
		if aiState.isAIPaneVisible {
			setAIPaneVisible(true, focus: false)
		}
		sidebarSplitViewItem?.isCollapsed = state.isSidebarHidden
	}

	static func savedUserDefaultsState() -> MainWindowState? {
		guard let data = AppDefaults.secureWindowState else {
			return nil
		}
		return try? NSKeyedUnarchiver.unarchivedObject(ofClass: MainWindowState.self, from: data)
	}

	/// Restore main window split view using legacy state restoration data.
	///
	/// TODO: Delete this for NetNewsWire 7.
	func restoreLegacySplitViewState(from state: [AnyHashable: Any]) {
		guard let splitView = splitViewController?.splitView,
			  let widths = state[MainWindowController.mainWindowWidthsStateKey] as? [Int],
			  widths.count == 3,
			  let window = window else {
			return
		}

		let windowWidth = Int(floor(window.frame.width))
		let dividerThickness: Int = Int(splitView.dividerThickness)
		let sidebarWidth: Int = widths[0]
		let timelineWidth: Int = widths[1]

		// Make sure the detail view has its minimum thickness, at least.
		if windowWidth < sidebarWidth + dividerThickness + timelineWidth + dividerThickness + Self.detailViewMinimumWidth {
			return
		}

		rememberedStandardLayoutWidths = widths
		applyRememberedGeometry()

		let isSidebarHidden = state[UserInfoKey.isSidebarHidden] as? Bool ?? false

		if !(sidebarSplitViewItem?.isCollapsed ?? false) && isSidebarHidden {
			sidebarSplitViewItem?.isCollapsed = true
		}
	}

	func buildToolbarButton(_ itemIdentifier: NSToolbarItem.Identifier, _ title: String, _ image: NSImage, _ selector: String) -> NSToolbarItem {
		let toolbarItem = RSToolbarItem(itemIdentifier: itemIdentifier)
		toolbarItem.autovalidates = true

		let button = NSButton()
		button.bezelStyle = .texturedRounded
		button.image = image
		button.imageScaling = .scaleProportionallyDown
		button.action = Selector((selector))

		toolbarItem.view = button
		toolbarItem.toolTip = title
		toolbarItem.label = title
		// A menu form representation keeps view-based items working in the toolbar's Text Only mode and overflow menu.
		toolbarItem.menuFormRepresentation = NSMenuItem(title: title, action: Selector((selector)), keyEquivalent: "")
		return toolbarItem
	}

	func buildNewSidebarItemMenu() -> NSMenu {
		let menu = NSMenu()

		let newFeedItem = NSMenuItem()
		newFeedItem.title = NSLocalizedString("New Feed…", comment: "Command")
		newFeedItem.action = #selector(AppDelegate.showAddFeedWindow(_:))
		menu.addItem(newFeedItem)

		let newFolderFeedItem = NSMenuItem()
		newFolderFeedItem.title = NSLocalizedString("New Folder…", comment: "Command")
		newFolderFeedItem.action = #selector(AppDelegate.showAddFolderWindow(_:))
		menu.addItem(newFolderFeedItem)

		return menu
	}

	func updateArticleThemeMenu() {
		guard let toolbarItem = window?.toolbar?.existingItem(withIdentifier: .articleThemeMenu) as? NSMenuToolbarItem else {
			return
		}
		toolbarItem.menu = ArticleThemesManager.shared.makeArticleThemeMenu()
	}

	// MARK: - Status Bar

	/// The status bar, when showing, takes the place of the detail view’s floating link overlay and the sidebar’s progress view.
	func updateStatusBarVisibility() {
		let showStatusBar = AppDefaults.showStatusBar
		mainWindowContentViewController.isStatusBarHidden = !showStatusBar
		detailViewController?.showsMouseoverLinkOverlay = !showStatusBar
		sidebarViewController?.showsProgressView = !showStatusBar
	}

	func updateStatusBarLink() {
		mainWindowContentViewController.statusBarView.link = mouseoverLink ?? currentLink
	}

	/// Tracks the sidebar divider in the status bar. Call after the split view controller is replaced.
	func observeSplitViewForStatusBar() {
		NotificationCenter.default.removeObserver(self, name: NSSplitView.didResizeSubviewsNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: NSSplitView.willResizeSubviewsNotification, object: nil)
		if let splitView = splitViewController?.splitView {
			NotificationCenter.default.addObserver(self, selector: #selector(handleSplitViewDidResizeSubviews(_:)), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
			NotificationCenter.default.addObserver(self, selector: #selector(handleSplitViewWillResizeSubviews(_:)), name: NSSplitView.willResizeSubviewsNotification, object: splitView)
		}
		updateStatusBarSidebarDivider()
	}

	@objc func handleSplitViewWillResizeSubviews(_ notification: Notification) {
		// Lower the required minimum before each drag step so the divider can move
		// freely in both directions; the width is locked again when the drag ends.
		guard isAIPaneVisible, let splitView = splitViewController?.splitView, splitView.inLiveResize == true, NSEvent.pressedMouseButtons != 0 else {
			return
		}
		guard isPointerOnAIDivider(in: splitView) else {
			return
		}
		isUserResizingAIPane = true
		if let aiSplitViewItem, aiSplitViewItem.minimumThickness > Self.aiPaneMinimumWidth {
			aiSplitViewItem.minimumThickness = Self.aiPaneMinimumWidth
		}
	}

	@objc func handleSplitViewDidResizeSubviews(_ notification: Notification) {
		updateStatusBarSidebarDivider()
		updateAIPaneWidthAfterResize()
	}

	func isPointerOnAIDivider(in splitView: NSSplitView) -> Bool {
		guard let aiView = splitView.arrangedSubviews.last, let window = splitView.window else {
			return false
		}
		let dividerPosition = aiView.frame.minX - splitView.dividerThickness
		let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
		let splitPoint = splitView.convert(windowPoint, from: nil)
		return abs(splitPoint.x - dividerPosition) <= 6
	}

	/// The split view controller ignores programmatic divider positions for a pane
	/// added after layout, but it does honor the item's required minimum thickness.
	/// A drag leaves no other record of the width it ended at, so read it from the
	/// pointer and turn it into the item's minimum once the drag is over; otherwise
	/// the pane snaps back to its minimum and the remembered width is lost.
	func updateAIPaneWidthAfterResize() {
		guard isUserResizingAIPane, isAIPaneVisible, let splitView = splitViewController?.splitView, let aiView = splitView.arrangedSubviews.last else {
			return
		}
		if splitView.inLiveResize == true {
			return
		}

		let pointerWidth: CGFloat?
		if let window = splitView.window {
			let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
			let splitPoint = splitView.convert(windowPoint, from: nil)
			pointerWidth = splitView.bounds.width - splitPoint.x - (splitView.dividerThickness / 2)
		} else {
			pointerWidth = nil
		}
		let finalWidth = max(pointerWidth ?? aiView.frame.width, Self.aiPaneMinimumWidth)
		rememberedAIPaneWidth = Int(floor(finalWidth))
		isUserResizingAIPane = false
		// The split view controller ignores a minimum-thickness change made from
		// inside the resize notification, so apply it on the next run loop turn.
		Task { @MainActor in
			guard self.isAIPaneVisible, let aiSplitViewItem = self.aiSplitViewItem else {
				return
			}
			aiSplitViewItem.minimumThickness = finalWidth
		}
	}

	func updateStatusBarSidebarDivider() {
		let statusBarView = mainWindowContentViewController.statusBarView
		guard let sidebarSplitViewItem, !sidebarSplitViewItem.isCollapsed, let splitView = splitViewController?.splitView, let sidebarPane = splitView.arrangedSubviews.first else {
			statusBarView.sidebarDividerPosition = nil
			return
		}
		// Use the split view’s sidebar pane, not the sidebar view: while the sidebar slides in,
		// the sidebar view’s position lags a step behind the pane and isn’t updated after the last resize.
		let dividerPositionInStatusBar = statusBarView.convert(NSPoint(x: sidebarPane.frame.maxX, y: 0), from: splitView)

		// Starting with macOS 26, the content beside the sidebar extends under it, and the divider is a hairline
		// at the sidebar’s trailing edge. Before that, the divider follows the sidebar.
		let arrangedSubviews = splitView.arrangedSubviews
		if arrangedSubviews.count > 1 {
			let contentExtendsUnderSidebar = arrangedSubviews[1].frame.minX < sidebarPane.frame.maxX
			let hairline = 1 / (window?.backingScaleFactor ?? 1)
			statusBarView.sidebarDividerLineOffset = contentExtendsUnderSidebar ? -hairline : 0
			statusBarView.sidebarDividerLineWidth = contentExtendsUnderSidebar ? hairline : splitView.dividerThickness
		}
		statusBarView.sidebarDividerPosition = dividerPositionInStatusBar.x
	}
}
