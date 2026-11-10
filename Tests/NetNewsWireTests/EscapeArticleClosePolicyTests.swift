//
//  EscapeArticleClosePolicyTests.swift
//  NetNewsWireTests
//

import Testing

@testable import NetNewsWire

struct EscapeArticleClosePolicyTests {

	@Test func closesTheSelectedArticleInTheMainWindow() {
		let policy = makePolicy()

		#expect(policy.shouldCloseSelectedArticle)
	}

	@Test func doesNotCloseWhileATextInputHasFocus() {
		let policy = makePolicy(isTextInputFirstResponder: true)

		#expect(!policy.shouldCloseSelectedArticle)
	}

	@Test func doesNotCloseWhileTheArticleBodyHasFocus() {
		let policy = makePolicy(isArticleBodyFirstResponder: true)

		#expect(!policy.shouldCloseSelectedArticle)
	}

	@Test func doesNotCloseWhileASheetOrModalWindowIsInFront() {
		let policy = makePolicy(hasModalWindowOrSheet: true)

		#expect(!policy.shouldCloseSelectedArticle)
	}

	@Test func doesNotCloseWhenNoArticleIsSelected() {
		let policy = makePolicy(hasSelectedArticle: false)

		#expect(!policy.shouldCloseSelectedArticle)
	}
}

// MARK: - Helpers

private func makePolicy(
	hasSelectedArticle: Bool = true,
	isTextInputFirstResponder: Bool = false,
	hasModalWindowOrSheet: Bool = false,
	isArticleBodyFirstResponder: Bool = false
) -> EscapeArticleClosePolicy {
	EscapeArticleClosePolicy(
		hasSelectedArticle: hasSelectedArticle,
		isTextInputFirstResponder: isTextInputFirstResponder,
		hasModalWindowOrSheet: hasModalWindowOrSheet,
		isArticleBodyFirstResponder: isArticleBodyFirstResponder
	)
}
