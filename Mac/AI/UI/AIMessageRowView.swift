//
//  AIMessageRowView.swift
//  NetNewsWire
//

import AppKit
import AI

/// One chat bubble: user bubbles hug the trailing edge, assistant bubbles the leading edge.
final class AIMessageRowView: NSView {

	private let bubble = NSView()
	private let label = NSTextField(wrappingLabelWithString: "")
	private let isUser: Bool

	init(message: ChatMessage) {
		self.isUser = message.role == .user
		super.init(frame: .zero)
		configure()
		applyText(message.content)
	}

	init(text: String, isUser: Bool) {
		self.isUser = isUser
		super.init(frame: .zero)
		configure()
		applyText(text)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// Replaces the bubble's text while a reply streams in.
	func update(text: String) {
		applyText(text)
	}

	override func layout() {
		super.layout()
		let maximumBubbleWidth = max(80, bounds.width - (isUser ? 36 : 20))
		let horizontalInset: CGFloat = isUser ? 9 : 0
		let maximumLabelWidth = maximumBubbleWidth - horizontalInset * 2
		if abs(label.preferredMaxLayoutWidth - maximumLabelWidth) > 0.5 {
			label.preferredMaxLayoutWidth = maximumLabelWidth
			label.invalidateIntrinsicContentSize()
			invalidateIntrinsicContentSize()
		}
	}
}

private extension AIMessageRowView {

	func configure() {
		translatesAutoresizingMaskIntoConstraints = false

		bubble.translatesAutoresizingMaskIntoConstraints = false
		bubble.wantsLayer = true
		bubble.layer?.cornerRadius = isUser ? 10 : 0
		bubble.layer?.masksToBounds = true
		if isUser {
			bubble.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
		} else {
			bubble.layer?.backgroundColor = NSColor.clear.cgColor
		}

		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = .systemFont(ofSize: 13)
		label.maximumNumberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.isSelectable = true
		label.isEditable = false
		label.isBezeled = false
		label.drawsBackground = false
		label.textColor = isUser ? .white : .labelColor

		// Selectable labels hand clicks to the window's field editor. Without
		// this, the field editor shows a plain-string copy and drops Markdown.
		label.allowsEditingTextAttributes = !isUser

		addSubview(bubble)
		bubble.addSubview(label)

		let verticalInset: CGFloat = isUser ? 7 : 3
		let horizontalInset: CGFloat = isUser ? 9 : 0
		NSLayoutConstraint.activate([
			bubble.topAnchor.constraint(equalTo: topAnchor, constant: 3),
			bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
			label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: verticalInset),
			label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -verticalInset),
			label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: horizontalInset),
			label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -horizontalInset)
		])

		if isUser {
			NSLayoutConstraint.activate([
				bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
				bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28)
			])
		} else {
			NSLayoutConstraint.activate([
				bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
				bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
			])
		}
	}

	func applyText(_ text: String) {
		if isUser {
			label.stringValue = text
		} else {
			label.attributedStringValue = AIChatMarkdownRenderer.attributedString(from: text)
		}
		label.invalidateIntrinsicContentSize()
		invalidateIntrinsicContentSize()
		needsLayout = true
	}
}
