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
		configure(text: message.content)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func layout() {
		super.layout()
		let maximumBubbleWidth = max(80, bounds.width - 36)
		let maximumLabelWidth = maximumBubbleWidth - 18
		if abs(label.preferredMaxLayoutWidth - maximumLabelWidth) > 0.5 {
			label.preferredMaxLayoutWidth = maximumLabelWidth
			label.invalidateIntrinsicContentSize()
			invalidateIntrinsicContentSize()
		}
	}
}

private extension AIMessageRowView {

	func configure(text: String) {
		translatesAutoresizingMaskIntoConstraints = false

		bubble.translatesAutoresizingMaskIntoConstraints = false
		bubble.wantsLayer = true
		bubble.layer?.cornerRadius = 10
		bubble.layer?.masksToBounds = true
		if isUser {
			bubble.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
		} else {
			bubble.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor
		}

		label.translatesAutoresizingMaskIntoConstraints = false
		label.stringValue = text
		label.font = .systemFont(ofSize: 12)
		label.maximumNumberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.isSelectable = true
		label.isEditable = false
		label.isBezeled = false
		label.drawsBackground = false
		label.textColor = isUser ? .white : .labelColor

		addSubview(bubble)
		bubble.addSubview(label)

		NSLayoutConstraint.activate([
			bubble.topAnchor.constraint(equalTo: topAnchor, constant: 3),
			bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
			label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
			label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
			label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 9),
			label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -9)
		])

		if isUser {
			NSLayoutConstraint.activate([
				bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
				bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28)
			])
		} else {
			NSLayoutConstraint.activate([
				bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
				bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28)
			])
		}
	}
}
