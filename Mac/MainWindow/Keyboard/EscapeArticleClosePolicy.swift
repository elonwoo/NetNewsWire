//
//  EscapeArticleClosePolicy.swift
//  NetNewsWire
//

/// Decides whether Escape should clear the timeline’s article selection and
/// bring the task panel back. Kept free of AppKit state so the rules can be
/// tested directly.
struct EscapeArticleClosePolicy {

	/// One article is selected, so the reading pane is showing it.
	let hasSelectedArticle: Bool
	/// A field editor or text field has focus; Escape belongs to it.
	let isTextInputFirstResponder: Bool
	/// A sheet or app-modal window is in front; Escape belongs to it.
	let hasModalWindowOrSheet: Bool
	/// The article body web view has focus; Escape belongs to the page (video
	/// full screen exit, in-page handlers) and must not close the article.
	let isArticleBodyFirstResponder: Bool

	var shouldCloseSelectedArticle: Bool {
		hasSelectedArticle
			&& !isTextInputFirstResponder
			&& !hasModalWindowOrSheet
			&& !isArticleBodyFirstResponder
	}
}
