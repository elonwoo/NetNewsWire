//
//  AIPaneTabPolicy.swift
//  NetNewsWire
//

import Foundation

/// The tabs the reading area can show.
enum AIPaneTab: Equatable {
	case rewrite
	case original
	case translation
}

/// Decides which tabs a feed offers and which one the pane opens on.
///
/// Rewrite and translation are independent per-feed switches. The original is
/// always available; the other two follow their switch. An article that does
/// not allow AI (Chinese article in a feed without the language override) shows
/// only the original, even when a cached rewrite exists.
enum AIPaneTabPolicy {

	static func visibleTabs(rewriteEnabled: Bool, translationEnabled: Bool, articleAllowsAI: Bool = true) -> [AIPaneTab] {
		guard articleAllowsAI else {
			return [.original]
		}
		var tabs = [AIPaneTab]()
		if rewriteEnabled {
			tabs.append(.rewrite)
		} else if translationEnabled {
			tabs.append(.translation)
		}
		tabs.append(.original)
		if rewriteEnabled && translationEnabled {
			tabs.append(.translation)
		}
		return tabs
	}

	/// A cached rewrite wins over a cached body translation, which wins over the
	/// original. Disabled tabs are never chosen, even when their content exists.
	static func defaultTab(rewriteEnabled: Bool, hasRewrite: Bool, translationEnabled: Bool, hasBodyTranslation: Bool, articleAllowsAI: Bool = true) -> AIPaneTab {
		guard articleAllowsAI else {
			return .original
		}
		if rewriteEnabled && hasRewrite {
			return .rewrite
		}
		if translationEnabled && hasBodyTranslation {
			return .translation
		}
		return .original
	}

	/// Where a tab that just became hidden lands: a cached rewrite when rewrites
	/// are on, else the original. Toggling a switch never opens translation.
	static func fallbackTab(rewriteEnabled: Bool, hasRewrite: Bool, articleAllowsAI: Bool = true) -> AIPaneTab {
		guard articleAllowsAI else {
			return .original
		}
		if rewriteEnabled && hasRewrite {
			return .rewrite
		}
		return .original
	}
}
