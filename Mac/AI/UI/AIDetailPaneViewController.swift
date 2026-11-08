//
//  AIDetailPaneViewController.swift
//  NetNewsWire
//

import AppKit
import Articles

/// The reading area: a three-tab header (原文 / 中文改写 / 中文翻译) above the
/// existing article view, the Chinese rewrite view and the Chinese translation
/// view.
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
		}
	}

	private enum Tab: Int {
		case original = 0
		case rewrite = 1
		case translation = 2
	}

	private static let tabDefaultsKey = "aiDetailTab"

	private let tabBar = NSView()
	private let tabControl: NSSegmentedControl
	private let contentView = NSView()
	private var selectedTab: Tab

	init(detailViewController: DetailViewController, rewriteViewController: AIRewriteViewController = AIRewriteViewController(), translationViewController: AITranslationViewController = AITranslationViewController()) {
		self.detailViewController = detailViewController
		self.rewriteViewController = rewriteViewController
		self.translationViewController = translationViewController
		self.tabControl = NSSegmentedControl(labels: ["原文", "中文改写", "中文翻译"], trackingMode: .selectOne, target: nil, action: nil)
		if let stored = UserDefaults.standard.object(forKey: Self.tabDefaultsKey) as? Int, let tab = Tab(rawValue: stored) {
			self.selectedTab = tab
		} else {
			self.selectedTab = .rewrite
		}
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

	func updateVisibleContent() {
		detailViewController.view.isHidden = selectedTab != .original
		rewriteViewController.view.isHidden = selectedTab != .rewrite
		translationViewController.view.isHidden = selectedTab != .translation
	}

	@objc func tabChanged(_ sender: NSSegmentedControl) {
		selectedTab = Tab(rawValue: sender.selectedSegment) ?? .rewrite
		UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.tabDefaultsKey)
		updateVisibleContent()
		if selectedTab == .rewrite {
			rewriteViewController.refreshIfNeeded()
		}
	}
}
