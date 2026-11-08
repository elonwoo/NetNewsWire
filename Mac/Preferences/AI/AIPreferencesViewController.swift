//
//  AIPreferencesViewController.swift
//  NetNewsWire
//

import AppKit

/// Preferences pane for the local AI gateway: where requests go, which model
/// they use, and the API key that authenticates them.
final class AIPreferencesViewController: NSViewController {

	private static let preferredWidth: CGFloat = 512
	private static let preferredHeight: CGFloat = 300

	private let baseURLField = NSTextField(labelWithString: "")
	private let modelField = NSTextField(labelWithString: "")
	private let apiKeyField = NSSecureTextField()
	private let statusLabel = NSTextField(labelWithString: "")
	private let messageLabel = NSTextField(wrappingLabelWithString: "")

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let rootView = NSView(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: Self.preferredHeight))
		view = rootView

		let title = NSTextField(labelWithString: "AI 网关")
		title.font = .systemFont(ofSize: 15, weight: .semibold)

		let intro = NSTextField(wrappingLabelWithString: "译文、改写和对话都通过本地网关发送。填写网关 API key 后即可使用。")
		intro.font = .systemFont(ofSize: 12)
		intro.textColor = .secondaryLabelColor

		configureReadOnly(baseURLField, value: AIEnvironment.shared.config.baseURL.absoluteString)
		configureReadOnly(modelField, value: AIEnvironment.shared.config.model)

		apiKeyField.placeholderString = "网关 API key"
		apiKeyField.font = .systemFont(ofSize: 13)

		statusLabel.font = .systemFont(ofSize: 12)

		let keyRow = NSStackView(views: [apiKeyField, statusLabel])
		keyRow.orientation = .horizontal
		keyRow.alignment = .centerY
		keyRow.spacing = 10

		let grid = NSGridView(views: [
			[makeRowLabel("网关地址"), baseURLField],
			[makeRowLabel("模型"), modelField],
			[makeRowLabel("API key"), keyRow]
		])
		grid.rowSpacing = 8
		grid.columnSpacing = 12
		grid.column(at: 0).xPlacement = .trailing
		grid.column(at: 1).width = 340

		let separator = NSBox()
		separator.boxType = .separator

		let saveButton = NSButton(title: "保存", target: self, action: #selector(saveAPIKey))
		saveButton.bezelStyle = .rounded
		saveButton.keyEquivalent = "\r"

		let clearButton = NSButton(title: "清除", target: self, action: #selector(clearAPIKey))
		clearButton.bezelStyle = .rounded

		let buttonRow = NSStackView(views: [saveButton, clearButton])
		buttonRow.orientation = .horizontal
		buttonRow.alignment = .centerY
		buttonRow.spacing = 8

		messageLabel.font = .systemFont(ofSize: 12)
		messageLabel.textColor = .secondaryLabelColor
		messageLabel.maximumNumberOfLines = 2

		let stack = NSStackView(views: [title, intro, separator, grid, buttonRow, messageLabel])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 10
		stack.translatesAutoresizingMaskIntoConstraints = false
		rootView.addSubview(stack)

		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
			stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
			stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
			stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -20),
			intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
			separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
			grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
			messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
		])

		updateStatus()
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		apiKeyField.stringValue = ""
		messageLabel.stringValue = ""
		updateStatus()
	}
}

// MARK: - Actions

private extension AIPreferencesViewController {

	@objc func saveAPIKey() {
		let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !apiKey.isEmpty else {
			showMessage("请输入 API key。", isError: false)
			return
		}

		do {
			try AIEnvironment.shared.updateAPIKey(apiKey)
			apiKeyField.stringValue = ""
			showMessage("已保存。", isError: false)
			updateStatus()
		} catch {
			showMessage("保存失败：\(error.localizedDescription)", isError: true)
		}
	}

	@objc func clearAPIKey() {
		do {
			try AIEnvironment.shared.updateAPIKey("")
			apiKeyField.stringValue = ""
			showMessage("已清除。", isError: false)
			updateStatus()
		} catch {
			showMessage("清除失败：\(error.localizedDescription)", isError: true)
		}
	}
}

// MARK: - Helpers

private extension AIPreferencesViewController {

	func makeRowLabel(_ text: String) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = .systemFont(ofSize: 13)
		return label
	}

	func configureReadOnly(_ field: NSTextField, value: String) {
		field.stringValue = value
		field.isSelectable = true
		field.isEditable = false
		field.isBezeled = false
		field.drawsBackground = false
		field.font = .systemFont(ofSize: 13)
		field.textColor = .secondaryLabelColor
		field.lineBreakMode = .byTruncatingMiddle
	}

	func updateStatus() {
		if AIEnvironment.shared.hasAPIKey {
			statusLabel.stringValue = "已配置"
			statusLabel.textColor = .systemGreen
		} else {
			statusLabel.stringValue = "未配置"
			statusLabel.textColor = .secondaryLabelColor
		}
	}

	func showMessage(_ message: String, isError: Bool) {
		messageLabel.stringValue = message
		messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
	}
}
