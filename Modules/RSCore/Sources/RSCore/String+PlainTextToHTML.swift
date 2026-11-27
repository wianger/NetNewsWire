//
//  String+PlainTextToHTML.swift
//  RSCore
//
//  Created by Brent Simmons on 10/23/26.
//

import Foundation

#if canImport(Darwin)
private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
#endif
private let linkSchemes: Set = ["http", "https", "mailto"]

public extension String {

	/// HTML for plain text: escaped, with blank lines as paragraph breaks,
	/// other line breaks as `<br>`, and URLs as links.
	var convertingPlainTextToHTML: String {
		let lines = replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

		var paragraphs = [String]()
		var paragraphLines = [String]()
		func endParagraph() {
			if !paragraphLines.isEmpty {
				paragraphs.append("<p>" + paragraphLines.joined(separator: "<br>\n") + "</p>")
				paragraphLines.removeAll()
			}
		}

		for line in lines {
			if line.trimmingCharacters(in: .whitespaces).isEmpty {
				endParagraph()
			} else {
				paragraphLines.append(Self.linkifiedEscapedLine(line))
			}
		}
		endParagraph()

		return paragraphs.joined(separator: "\n")
	}
}

private extension String {

	#if canImport(Darwin)
	static func linkifiedEscapedLine(_ line: String) -> String {
		guard let linkDetector else {
			return line.escapingSpecialXMLCharacters
		}

		let nsLine = line as NSString
		var html = ""
		var location = 0
		for match in linkDetector.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
			guard let url = match.url, let scheme = url.scheme?.lowercased(), linkSchemes.contains(scheme) else {
				continue
			}
			html += nsLine.substring(with: NSRange(location: location, length: match.range.location - location)).escapingSpecialXMLCharacters
			let linkText = nsLine.substring(with: match.range).escapingSpecialXMLCharacters
			html += "<a href=\"\(url.absoluteString.escapingSpecialXMLCharacters)\">\(linkText)</a>"
			location = match.range.location + match.range.length
		}
		html += nsLine.substring(from: location).escapingSpecialXMLCharacters
		return html
	}
	#else
	/// NSDataDetector is not available outside Apple platforms. This matches explicit
	/// http, https and mailto URLs, which covers what feeds put in plain text.
	static func linkifiedEscapedLine(_ line: String) -> String {
		var html = ""
		var remainder = line[...]
		while let match = remainder.firstMatch(of: plainTextLinkPattern) {
			var linkText = String(match.output)
			// Trailing punctuation is almost always sentence punctuation, not part of the URL.
			while let last = linkText.last, ".,;:!?)]}'\"".contains(last) {
				linkText.removeLast()
			}
			let linkEnd = remainder.index(match.range.lowerBound, offsetBy: linkText.count)
			html += remainder[..<match.range.lowerBound].description.escapingSpecialXMLCharacters
			if let url = URL(string: linkText), let scheme = url.scheme?.lowercased(), linkSchemes.contains(scheme) {
				let escapedLinkText = linkText.escapingSpecialXMLCharacters
				html += "<a href=\"\(url.absoluteString.escapingSpecialXMLCharacters)\">\(escapedLinkText)</a>"
			} else {
				html += linkText.escapingSpecialXMLCharacters
			}
			remainder = remainder[linkEnd...]
		}
		html += String(remainder).escapingSpecialXMLCharacters
		return html
	}
	#endif
}

#if !canImport(Darwin)
nonisolated(unsafe) private let plainTextLinkPattern = /(?i)(?:https?:\/\/|mailto:)[^\s<>"]+/
#endif
