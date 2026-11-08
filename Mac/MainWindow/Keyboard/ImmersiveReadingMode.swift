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

	// Keyed by window, then by pane view controller. The panes live for the window's life,
	// so their identity survives a split view rebuild when the timeline layout changes.
	private var savedPaneStates = [ObjectIdentifier: [ObjectIdentifier: PaneState]]()

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
		return true
	}

	private func enter(for window: NSWindow?) {
		guard let window, savedPaneStates[ObjectIdentifier(window)] == nil else {
			return
		}
		guard let splitViewController = mainSplitViewController(for: window),
			  let detailViewController = detailViewController(in: splitViewController) else {
			return
		}

		var savedStates = [ObjectIdentifier: PaneState]()
		for item in splitViewController.allSplitViewItemsRecursively {
			savedStates[ObjectIdentifier(item.viewController)] = PaneState(isCollapsed: item.isCollapsed, canCollapse: item.canCollapse)
		}
		savedPaneStates[ObjectIdentifier(window)] = savedStates

		for item in splitViewController.allSplitViewItemsRecursively where !isOnDetailPath(item.viewController, detailViewController: detailViewController) {
			item.canCollapse = true
			item.isCollapsed = true
		}

		// Keep keyboard events flowing through the article view while the other panes are hidden.
		detailViewController.focus()
	}

	private func mainSplitViewController(for window: NSWindow) -> NSSplitViewController? {
		(window.contentViewController as? MainWindowContentViewController)?.splitViewController
	}

	private func detailViewController(in splitViewController: NSSplitViewController) -> DetailViewController? {
		splitViewController.allSplitViewItemsRecursively.compactMap { $0.viewController as? DetailViewController }.first
	}

	/// A pane stays visible when it is the article view or contains it.
	private func isOnDetailPath(_ viewController: NSViewController, detailViewController: DetailViewController) -> Bool {
		var current: NSViewController? = detailViewController
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
