//
//  MainWindowState.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 12/16/23.
//  Copyright © 2023 Ranchero Software. All rights reserved.
//

import Foundation

final class MainWindowState: NSObject, NSSecureCoding {

	static let supportsSecureCoding = true

	let isFullScreen: Bool
	let splitViewWidths: [Int]
	// Timeline height in column layout. Zero when never saved.
	let columnLayoutTimelineHeight: Int
	let isSidebarHidden: Bool
	// The AI pane’s visibility and width. Zero width means never saved.
	let isAIPaneVisible: Bool
	let aiPaneWidth: Int
	let sidebarWindowState: SidebarWindowState?
	let timelineWindowState: TimelineWindowState?
	let detailWindowState: DetailWindowState?

	init(isFullScreen: Bool, splitViewWidths: [Int], columnLayoutTimelineHeight: Int = 0, isSidebarHidden: Bool, isAIPaneVisible: Bool = false, aiPaneWidth: Int = 0, sidebarWindowState: SidebarWindowState? = nil, timelineWindowState: TimelineWindowState? = nil, detailWindowState: DetailWindowState? = nil) {
		self.isFullScreen = isFullScreen
		self.splitViewWidths = splitViewWidths
		self.columnLayoutTimelineHeight = columnLayoutTimelineHeight
		self.isSidebarHidden = isSidebarHidden
		self.isAIPaneVisible = isAIPaneVisible
		self.aiPaneWidth = aiPaneWidth
		self.sidebarWindowState = sidebarWindowState
		self.timelineWindowState = timelineWindowState
		self.detailWindowState = detailWindowState
	}

	private struct Key {
		static let isFullScreen = "isFullScreen"
		static let splitViewWidths = "splitViewWidths"
		static let columnLayoutTimelineHeight = "columnLayoutTimelineHeight"
		static let isSidebarHidden = "isSidebarHidden"
		static let isAIPaneVisible = "isAIPaneVisible"
		static let aiPaneWidth = "aiPaneWidth"
		static let sidebarWindowState = "sidebarWindowState"
		static let timelineWindowState = "timelineWindowState"
		static let detailWindowState = "detailWindowState"
	}

	required init?(coder: NSCoder) {
		isFullScreen = coder.decodeBool(forKey: Key.isFullScreen)
		splitViewWidths = coder.decodeObject(of: [NSArray.self, NSNumber.self], forKey: Key.splitViewWidths) as? [Int] ?? []
		columnLayoutTimelineHeight = coder.decodeInteger(forKey: Key.columnLayoutTimelineHeight)
		isSidebarHidden = coder.decodeBool(forKey: Key.isSidebarHidden)
		isAIPaneVisible = coder.decodeBool(forKey: Key.isAIPaneVisible)
		aiPaneWidth = coder.decodeInteger(forKey: Key.aiPaneWidth)
		sidebarWindowState = coder.decodeObject(of: SidebarWindowState.self, forKey: Key.sidebarWindowState)
		timelineWindowState = coder.decodeObject(of: TimelineWindowState.self, forKey: Key.timelineWindowState)
		detailWindowState = coder.decodeObject(of: DetailWindowState.self, forKey: Key.detailWindowState)
	}

	func encode(with coder: NSCoder) {
		coder.encode(isFullScreen, forKey: Key.isFullScreen)
		coder.encode(splitViewWidths, forKey: Key.splitViewWidths)
		coder.encode(columnLayoutTimelineHeight, forKey: Key.columnLayoutTimelineHeight)
		coder.encode(isSidebarHidden, forKey: Key.isSidebarHidden)
		coder.encode(isAIPaneVisible, forKey: Key.isAIPaneVisible)
		coder.encode(aiPaneWidth, forKey: Key.aiPaneWidth)
		coder.encode(sidebarWindowState, forKey: Key.sidebarWindowState)
		coder.encode(timelineWindowState, forKey: Key.timelineWindowState)
		coder.encode(detailWindowState, forKey: Key.detailWindowState)
	}

	override var description: String {
		let sidebar = sidebarWindowState?.description ?? "nil"
		let timeline = timelineWindowState?.description ?? "nil"
		let detail = detailWindowState?.description ?? "nil"
		return "MainWindowState: fullScreen=\(isFullScreen), widths=\(splitViewWidths), timelineHeight=\(columnLayoutTimelineHeight), sidebarHidden=\(isSidebarHidden), aiVisible=\(isAIPaneVisible), aiWidth=\(aiPaneWidth), sidebar=[\(sidebar)], timeline=[\(timeline)], detail=[\(detail)]"
	}
}
