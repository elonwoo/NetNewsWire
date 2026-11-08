//
//  AIDetailPaneViewController.swift
//  NetNewsWire
//

import AppKit
import Articles

/// The reading area: a two-tab header (原文 / 中文) above the existing article view
/// and the Chinese translation view.
@MainActor
final class AIDetailPaneViewController: NSViewController {

	let detailViewController: DetailViewController
	let translationViewController: AITranslationViewController

	var article: Article? {
		didSet {
			guard article?.articleID != oldValue?.articleID else {
				return
			}
			translationViewController.article = article
		}
	}

	private enum Tab: Int {
		case original = 0
		case chinese = 1
	}

	private static let tabDefaultsKey = "aiDetailTab"

	private let tabBar = NSView()
	private let tabControl: NSSegmentedControl
	private let contentView = NSView()
	private var selectedTab: Tab

	init(detailViewController: DetailViewController, translationViewController: AITranslationViewController = AITranslationViewController()) {
		self.detailViewController = detailViewController
		self.translationViewController = translationViewController
		self.tabControl = NSSegmentedControl(labels: ["原文", "中文"], trackingMode: .selectOne, target: nil, action: nil)
		self.selectedTab = Tab(rawValue: UserDefaults.standard.integer(forKey: Self.tabDefaultsKey)) ?? .original
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

		addChild(translationViewController)
		let translationView = translationViewController.view
		translationView.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(translationView)

		for childView in [detailView, translationView] {
			NSLayoutConstraint.activate([
				childView.topAnchor.constraint(equalTo: contentView.topAnchor),
				childView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
				childView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
				childView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
			])
		}

		updateVisibleContent()
	}

	func focus() {
		switch selectedTab {
		case .original:
			detailViewController.focus()
		case .chinese:
			translationViewController.focus()
		}
	}
}

private extension AIDetailPaneViewController {

	func updateVisibleContent() {
		let showsChinese = selectedTab == .chinese
		detailViewController.view.isHidden = showsChinese
		translationViewController.view.isHidden = !showsChinese
	}

	@objc func tabChanged(_ sender: NSSegmentedControl) {
		selectedTab = Tab(rawValue: sender.selectedSegment) ?? .original
		UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.tabDefaultsKey)
		updateVisibleContent()
	}
}
