//
//  AIDetailPaneViewController.swift
//  NetNewsWire
//

import AI
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
			guard article?.articleID != oldValue?.articleID else {
				return
			}
			rewriteViewController.article = article
			translationViewController.article = article
			updateTabTitles()
			updateDefaultTab()
		}
	}

	private enum Tab: Int {
		case rewrite = 0
		case original = 1
		case translation = 2
	}

	private let tabBar = NSView()
	private let tabControl: NSSegmentedControl
	private let contentView = NSView()
	private var selectedTab: Tab
	private var defaultTabToken: UUID?

	init(detailViewController: DetailViewController, rewriteViewController: AIRewriteViewController = AIRewriteViewController(), translationViewController: AITranslationViewController = AITranslationViewController()) {
		self.detailViewController = detailViewController
		self.rewriteViewController = rewriteViewController
		self.translationViewController = translationViewController
		self.tabControl = NSSegmentedControl(labels: ["改写", "原文", "翻译"], trackingMode: .selectOne, target: nil, action: nil)
		self.selectedTab = .rewrite
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
		tabControl.selectedSegment = selectedTab.rawValue
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
		updateTabTitles()
		updateVisibleContent()
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
		tabControl.setLabel(rewriteViewController.tabTitle, forSegment: Tab.rewrite.rawValue)
	}

	/// Shows the rewrite when one is cached and the original otherwise. The store
	/// is read off the main actor, so a token stops a late answer for an article
	/// the reader has already left — or a tab they already picked — from
	/// switching the pane.
	func updateDefaultTab() {
		guard let article else {
			return
		}
		let articleID = article.articleID
		let token = UUID()
		defaultTabToken = token
		show(.original)

		Task { @MainActor in
			let rewrite = try? await AIEnvironment.shared.store.rewrite(for: articleID)
			guard self.defaultTabToken == token, rewrite != nil else {
				return
			}
			self.show(.rewrite)
		}
	}

	private func show(_ tab: Tab) {
		selectedTab = tab
		tabControl.selectedSegment = tab.rawValue
		updateVisibleContent()
	}

	func updateVisibleContent() {
		detailViewController.view.isHidden = selectedTab != .original
		rewriteViewController.view.isHidden = selectedTab != .rewrite
		translationViewController.view.isHidden = selectedTab != .translation
		translationViewController.setPaneVisible(selectedTab == .translation)
	}

	/// A rewrite that lands while the reader is still on the original takes the
	/// pane, which is where an article that already had one would have opened.
	@objc func rewriteDidBecomeReady(_ notification: Notification) {
		guard let articleID = notification.userInfo?[AIUserInfoKey.articleID] as? String,
		      articleID == article?.articleID,
		      selectedTab == .original else {
			return
		}
		defaultTabToken = nil
		show(.rewrite)
	}

	@objc func tabChanged(_ sender: NSSegmentedControl) {
		defaultTabToken = nil
		selectedTab = Tab(rawValue: sender.selectedSegment) ?? .rewrite
		updateVisibleContent()
		if selectedTab == .rewrite {
			rewriteViewController.refreshIfNeeded()
		}
		// The tab control keeps focus after a click, and it does not route the
		// reading shortcuts, so hand focus to the pane the reader just picked.
		focus()
	}
}
