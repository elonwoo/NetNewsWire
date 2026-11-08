//
//  AILocalization.swift
//  NetNewsWire
//

import Foundation

/// Localized UI strings for the AI features.
///
/// They live in their own `AIUI` string table so they do not collide with
/// NetNewsWire's existing `Localizable` catalog.
enum AILocalization {

	static func string(_ key: String, comment: String = "") -> String {
		NSLocalizedString(key, tableName: "AIUI", bundle: .main, value: key, comment: comment)
	}

	static func format(_ key: String, _ arguments: CVarArg...) -> String {
		String(format: string(key), arguments: arguments)
	}
}
