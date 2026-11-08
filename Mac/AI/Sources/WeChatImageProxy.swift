//
//  WeChatImageProxy.swift
//  NetNewsWire
//

import Foundation
import WebKit

/// Routes WeChat article images through the app.
///
/// `mmbiz.qpic.cn` rejects requests without a WeChat referer, so article HTML
/// is rewritten to a custom scheme and the handler downloads the image with
/// the right headers. Only that host is accepted.
enum WeChatImageRouter {

	static let scheme = "nnwWeChatImage"
	static let allowedHost = "mmbiz.qpic.cn"

	static var requestHeaders: [String: String] {
		[
			"Referer": "https://mp.weixin.qq.com/",
			"User-Agent": SourceHTTPRequest.browserUserAgent,
			"Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
		]
	}

	static func routedURLString(_ imageURL: String) -> String? {
		var normalized = HTMLTextExtractor.decodeEntities(imageURL).trimmingCharacters(in: .whitespacesAndNewlines)
		if normalized.hasPrefix("//") {
			normalized = "https:" + normalized
		}
		guard let url = URL(string: normalized), isAllowed(url) else {
			return nil
		}
		guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
			return nil
		}
		return "\(scheme):\(encoded)"
	}

	static func imageURL(from requestURL: URL) -> URL? {
		guard requestURL.scheme == scheme else {
			return nil
		}
		let encoded = requestURL.absoluteString.dropFirst(scheme.count + 1)
		guard let decoded = String(encoded).removingPercentEncoding,
			  let url = URL(string: decoded),
			  isAllowed(url) else {
			return nil
		}
		return url
	}

	static func isAllowed(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
			return false
		}
		guard let host = url.host?.lowercased() else {
			return false
		}
		return host == allowedHost || host.hasSuffix("." + allowedHost)
	}

	/// Rewrites `src` and `data-src` attributes that point at `mmbiz.qpic.cn`.
	static func rewriteHTML(_ html: String) -> String {
		let pattern = "(?i)(src|data-src)\\s*=\\s*([\"'])(https?://[^\"']*mmbiz\\.qpic\\.cn[^\"']*)\\2"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return html
		}

		let mutable = NSMutableString(string: html)
		let range = NSRange(location: 0, length: mutable.length)
		for match in regex.matches(in: html, range: range).reversed() {
			guard let attributeRange = Range(match.range(at: 1), in: html),
				  let quoteRange = Range(match.range(at: 2), in: html),
				  let urlRange = Range(match.range(at: 3), in: html) else {
				continue
			}
			let attribute = String(html[attributeRange])
			let quote = String(html[quoteRange])
			let imageURL = String(html[urlRange])
			guard let routed = routedURLString(imageURL) else {
				continue
			}
			mutable.replaceCharacters(in: match.range, with: "\(attribute)=\(quote)\(routed)\(quote)")
		}
		return mutable as String
	}
}

@MainActor final class WeChatImageSchemeHandler: NSObject, WKURLSchemeHandler {

	private let loader: any SourceHTTPLoading
	private let cache = NSCache<NSURL, NSData>()
	private var runningTaskIDs = Set<ObjectIdentifier>()

	init(loader: any SourceHTTPLoading = URLSessionSourceLoader()) {
		self.loader = loader
	}

	func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
		guard let requestURL = urlSchemeTask.request.url,
			  let imageURL = WeChatImageRouter.imageURL(from: requestURL) else {
			urlSchemeTask.didFailWithError(URLError(.badURL))
			return
		}

		if let cached = cache.object(forKey: imageURL as NSURL) {
			serve(cached as Data, for: requestURL, urlSchemeTask: urlSchemeTask)
			return
		}

		let taskID = ObjectIdentifier(urlSchemeTask)
		runningTaskIDs.insert(taskID)

		Task { @MainActor in
			var imageData: Data?
			var downloadError: Error?
			do {
				let response = try await loader.load(SourceHTTPRequest(url: imageURL, headers: WeChatImageRouter.requestHeaders))
				imageData = response.data
			} catch {
				downloadError = error
			}

			guard runningTaskIDs.remove(taskID) != nil else {
				return
			}
			guard let imageData else {
				urlSchemeTask.didFailWithError(downloadError ?? URLError(.cannotLoadFromNetwork))
				return
			}

			cache.setObject(imageData as NSData, forKey: imageURL as NSURL)
			serve(imageData, for: requestURL, urlSchemeTask: urlSchemeTask)
		}
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
		runningTaskIDs.remove(ObjectIdentifier(urlSchemeTask))
	}
}

private extension WeChatImageSchemeHandler {

	func serve(_ data: Data, for requestURL: URL, urlSchemeTask: WKURLSchemeTask) {
		let response = URLResponse(
			url: requestURL,
			mimeType: Self.mimeType(for: data),
			expectedContentLength: data.count,
			textEncodingName: nil
		)
		urlSchemeTask.didReceive(response)
		urlSchemeTask.didReceive(data)
		urlSchemeTask.didFinish()
	}

	static func mimeType(for data: Data) -> String {
		let bytes = [UInt8](data.prefix(12))
		if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
			return "image/jpeg"
		}
		if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
			return "image/png"
		}
		if bytes.starts(with: Array("GIF8".utf8)) {
			return "image/gif"
		}
		if bytes.count >= 12,
		   String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
		   String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" {
			return "image/webp"
		}
		if bytes.count >= 12 {
			let brand = String(decoding: bytes[4..<12], as: UTF8.self)
			if brand.hasPrefix("ftypavi") {
				return "image/avif"
			}
		}
		return "image/jpeg"
	}
}
