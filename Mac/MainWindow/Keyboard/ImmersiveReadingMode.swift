//
//  ImmersiveReadingMode.swift
//  NetNewsWire
//

import AppKit

/// Collapses every pane except the article view, so the article gets the whole window.
///
/// The pane states are captured on entry and restored on exit, so whichever panes were
/// collapsed or expanded before come back exactly as they were. This also covers panes
/// added by other parts of the app, such as an AI bar, because it walks the live split
/// view tree instead of assuming a fixed set of columns.
@MainActor
final class ImmersiveReadingMode {

	static let shared = ImmersiveReadingMode()

	private struct PaneState {
		let isCollapsed: Bool
		let canCollapse: Bool
	}

	// The toolbar is three sections stitched to the three columns. Hiding the first two
	// columns hides the items in their sections, but the section boundaries stay, so the
	// article section keeps the exact look it has when all three columns are visible.
	private struct ToolbarState {
		let hiddenItems: [NSToolbarItem]
		let titleVisibility: NSWindow.TitleVisibility
	}

	// Keyed by window, then by pane view controller. The panes live for the window's life,
	// so their identity survives a split view rebuild when the timeline layout changes.
	private var savedPaneStates = [ObjectIdentifier: [ObjectIdentifier: PaneState]]()
	private var savedDividerPositions = [ObjectIdentifier: [CGFloat]]()
	private var savedToolbarStates = [ObjectIdentifier: ToolbarState]()

	private init() {
	}

	func isActive(for window: NSWindow?) -> Bool {
		guard let window else {
			return false
		}
		return savedPaneStates[ObjectIdentifier(window)] != nil
	}

	func toggle(for window: NSWindow?) {
		if isActive(for: window) {
			exit(for: window)
		} else {
			enter(for: window)
		}
	}

	/// Returns true when immersive reading was active and has been left.
	@discardableResult
	func exit(for window: NSWindow?) -> Bool {
		guard let window, let savedStates = savedPaneStates.removeValue(forKey: ObjectIdentifier(window)) else {
			return false
		}
		guard let splitViewController = mainSplitViewController(for: window) else {
			return true
		}

		for item in splitViewController.allSplitViewItemsRecursively {
			guard let savedState = savedStates[ObjectIdentifier(item.viewController)] else {
				continue
			}
			item.canCollapse = true
			item.isCollapsed = savedState.isCollapsed
			item.canCollapse = savedState.canCollapse
		}
		restoreColumnWidths(in: splitViewController, savedDividerPositions: savedDividerPositions.removeValue(forKey: ObjectIdentifier(window)) ?? [])
		restoreToolbarSections(for: window)
		return true
	}

	/// Collapsing and re-expanding a pane resets it to its minimum width, so put
	/// the dividers back where the reader had them.
	private func restoreColumnWidths(in splitViewController: NSSplitViewController, savedDividerPositions: [CGFloat]) {
		let splitView = splitViewController.splitView
		for (index, position) in savedDividerPositions.enumerated() {
			guard index < splitView.arrangedSubviews.count - 1, !splitViewController.splitViewItems[index].isCollapsed else {
				continue
			}
			splitView.setPosition(position, ofDividerAt: index)
		}
	}

	/// Hides the items in the sidebar and timeline sections, tracking separators
	/// included, so nothing is left of the first two sections. The window title sits
	/// in the timeline section, so it goes too.
	private func hideToolbarSections(for window: NSWindow) {
		guard let toolbar = window.toolbar else {
			return
		}
		let separatorIdentifiers: Set<NSToolbarItem.Identifier> = [.sidebarTrackingSeparator, .timelineTrackingSeparator]
		guard let lastSeparatorIndex = toolbar.items.lastIndex(where: { separatorIdentifiers.contains($0.itemIdentifier) }) else {
			return
		}
		let hiddenItems = Array(toolbar.items[0...lastSeparatorIndex])
		for item in hiddenItems {
			item.isHidden = true
		}
		savedToolbarStates[ObjectIdentifier(window)] = ToolbarState(hiddenItems: hiddenItems, titleVisibility: window.titleVisibility)
		window.titleVisibility = .hidden
	}

	private func restoreToolbarSections(for window: NSWindow) {
		guard let state = savedToolbarStates.removeValue(forKey: ObjectIdentifier(window)) else {
			return
		}
		window.titleVisibility = state.titleVisibility
		for item in state.hiddenItems {
			item.isHidden = false
		}
	}

	private func enter(for window: NSWindow?) {
		guard let window, savedPaneStates[ObjectIdentifier(window)] == nil else {
			return
		}
		guard let splitViewController = mainSplitViewController(for: window),
			  let detailPaneViewController = detailPaneViewController(in: splitViewController) else {
			return
		}

		var savedStates = [ObjectIdentifier: PaneState]()
		for item in splitViewController.allSplitViewItemsRecursively {
			savedStates[ObjectIdentifier(item.viewController)] = PaneState(isCollapsed: item.isCollapsed, canCollapse: item.canCollapse)
		}
		savedPaneStates[ObjectIdentifier(window)] = savedStates

		let splitView = splitViewController.splitView
		let dividerCount = min(2, max(0, splitView.arrangedSubviews.count - 1))
		savedDividerPositions[ObjectIdentifier(window)] = (0..<dividerCount).map { splitView.arrangedSubviews[$0].frame.maxX }

		hideToolbarSections(for: window)

		// The AI bar belongs with the article, not with the timeline: it keeps
		// whichever state the reader left it in.
		for item in splitViewController.allSplitViewItemsRecursively
		where !isOnDetailPath(item.viewController, detailPaneViewController: detailPaneViewController)
			&& !(item.viewController is AIChatViewController) {
			item.canCollapse = true
			item.isCollapsed = true
		}

		// Keep keyboard events flowing through the article view while the other panes are hidden.
		detailPaneViewController.focus()
	}

	private func mainSplitViewController(for window: NSWindow) -> NSSplitViewController? {
		(window.contentViewController as? MainWindowContentViewController)?.splitViewController
	}

	/// The reading pane is the AI detail pane, which hosts the article view, the
	/// rewrite view and the translation view; collapsing it would hide the article.
	private func detailPaneViewController(in splitViewController: NSSplitViewController) -> AIDetailPaneViewController? {
		splitViewController.allSplitViewItemsRecursively.compactMap { $0.viewController as? AIDetailPaneViewController }.first
	}

	/// A pane stays visible when it is the reading pane or contains it.
	private func isOnDetailPath(_ viewController: NSViewController, detailPaneViewController: AIDetailPaneViewController) -> Bool {
		var current: NSViewController? = detailPaneViewController
		while let ancestor = current {
			if ancestor === viewController {
				return true
			}
			current = ancestor.parent
		}
		return false
	}
}

extension NSSplitViewController {

	/// Every split view item in this split view and in any split view controller nested inside it.
	var allSplitViewItemsRecursively: [NSSplitViewItem] {
		splitViewItems + splitViewItems.compactMap { $0.viewController as? NSSplitViewController }.flatMap { $0.allSplitViewItemsRecursively }
	}
}
