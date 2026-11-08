//
//  MainWindowKeyboardActions.swift
//  NetNewsWire
//

import AppKit

/// Actions reached from `GlobalKeyboardShortcuts.plist` through the responder chain.
extension MainWindowController {

	@IBAction func selectNextArticle(_ sender: Any?) {
		timelineContainerViewController(in: window)?.currentTimelineViewController?.selectNextDown(sender)
	}

	@IBAction func selectPreviousArticle(_ sender: Any?) {
		timelineContainerViewController(in: window)?.currentTimelineViewController?.selectNextUp(sender)
	}

	@IBAction func askAI(_ sender: Any?) {
		// The AI bar listens for this notification. The name is the contract between the two sides.
		NotificationCenter.default.post(name: Notification.Name("AIAskRequested"), object: window)
	}

	@IBAction func toggleImmersiveReading(_ sender: Any?) {
		ImmersiveReadingMode.shared.toggle(for: window)
	}
}

private extension MainWindowController {

	func timelineContainerViewController(in window: NSWindow?) -> TimelineContainerViewController? {
		guard let splitViewController = (window?.contentViewController as? MainWindowContentViewController)?.splitViewController else {
			return nil
		}
		return splitViewController.allSplitViewItemsRecursively.compactMap { $0.viewController as? TimelineContainerViewController }.first
	}
}
