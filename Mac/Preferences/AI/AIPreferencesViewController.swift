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

	private let baseURLField = NSTextField()
	private let modelField = NSTextField()
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

		configureEditable(baseURLField, placeholder: "http://127.0.0.1:3425/v1")
		configureEditable(modelField, placeholder: "deepseek-v4.1-flash")

		apiKeyField.placeholderString = "网关 API key"
		apiKeyField.font = .systemFont(ofSize: 13)
		apiKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
		apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

		statusLabel.font = .systemFont(ofSize: 12)
		statusLabel.setContentHuggingPriority(.required, for: .horizontal)
		statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

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
		baseURLField.stringValue = AIEnvironment.shared.config.baseURL.absoluteString
		modelField.stringValue = AIEnvironment.shared.config.model
		apiKeyField.stringValue = ""
		messageLabel.stringValue = ""
		updateStatus()
	}
}

// MARK: - Actions

private extension AIPreferencesViewController {

	@objc func saveAPIKey() {
		let baseURLString = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let baseURL = URL(string: baseURLString),
			  let scheme = baseURL.scheme?.lowercased(),
			  scheme == "http" || scheme == "https",
			  baseURL.host?.isEmpty == false else {
			showMessage("网关地址无效，需要以 http:// 或 https:// 开头。", isError: true)
			return
		}

		let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !model.isEmpty else {
			showMessage("请填写模型名。", isError: true)
			return
		}

		let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

		do {
			try AIEnvironment.shared.updateGateway(baseURL: baseURL, model: model, apiKey: apiKey.isEmpty ? nil : apiKey)
			apiKeyField.stringValue = ""
			messageLabel.stringValue = ""
			updateStatus()
		} catch {
			showMessage("保存失败：\(error.localizedDescription)", isError: true)
		}
	}

	@objc func clearAPIKey() {
		do {
			try AIEnvironment.shared.updateAPIKey("")
			apiKeyField.stringValue = ""
			messageLabel.stringValue = ""
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

	func configureEditable(_ field: NSTextField, placeholder: String) {
		field.placeholderString = placeholder
		field.font = .systemFont(ofSize: 13)
		field.isEditable = true
		field.isSelectable = true
		field.isBezeled = true
		field.bezelStyle = .roundedBezel
		field.setContentHuggingPriority(.defaultLow, for: .horizontal)
		field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
	}

	func updateStatus() {
		if AIEnvironment.shared.hasAPIKey {
			statusLabel.stringValue = "已配置"
			statusLabel.textColor = .systemGreen
			// The stored key never goes back into the field, so the placeholder
			// carries the masked hint instead. Typing replaces it on save.
			apiKeyField.placeholderString = "••••••••••••（已保存）"
		} else {
			statusLabel.stringValue = "未配置"
			statusLabel.textColor = .secondaryLabelColor
			apiKeyField.placeholderString = "网关 API key"
		}
	}

	func showMessage(_ message: String, isError: Bool) {
		messageLabel.stringValue = message
		messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
	}
}
