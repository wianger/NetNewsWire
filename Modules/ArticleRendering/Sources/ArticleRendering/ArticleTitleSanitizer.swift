//
//  ArticleTitleSanitizer.swift
//  ArticleRendering
//
//  Moved from ArticleStringFormatter (Shared/Extensions), which forwards to it,
//  so the article renderer on every platform sanitizes titles the same way.
//

import Foundation

public enum ArticleTitleSanitizer {

	/// Sanitize an article title that may contain HTML. Returns nil
	/// iff `title` is nil.
	///
	/// A tag is allowed or disallowed by its name alone (the leading run
	/// of letters after any `/`); attributes are ignored, so
	/// `<abbr title="…">` is recognized as `abbr`.
	///
	/// Behavior per (allowed, forHTML) combination:
	/// - allowed tag, forHTML=true: tag preserved (`<b>Bold</b>`).
	/// - allowed tag, forHTML=false: tag dropped, contents kept.
	/// - disallowed tag, forHTML=true: tag escaped as `&lt;...&gt;`.
	/// - disallowed tag, forHTML=false: tag preserved literally
	///   (a later `strippingHTML` pass removes it).
	///
	/// Single pass over UTF-8 bytes. Non-ASCII bytes pass through
	/// unchanged — correct for multi-byte text content.
	public static func sanitizedTitle(_ title: String?, forHTML: Bool) -> String? {
		guard let title else {
			return nil
		}
		if title.isEmpty {
			return ""
		}

		let utf8 = Array(title.utf8)
		let count = utf8.count
		var out = [UInt8]()
		out.reserveCapacity(count)

		let lt = UInt8(ascii: "<")
		let gt = UInt8(ascii: ">")
		let slash = UInt8(ascii: "/")
		// Pre-encoded `&lt;` / `&gt;` so the escape path doesn't
		// convert String to UTF-8 per tag.
		let ltEntity: [UInt8] = [
			UInt8(ascii: "&"), UInt8(ascii: "l"), UInt8(ascii: "t"), UInt8(ascii: ";")
		]
		let gtEntity: [UInt8] = [
			UInt8(ascii: "&"), UInt8(ascii: "g"), UInt8(ascii: "t"), UInt8(ascii: ";")
		]

		var i = 0
		while i < count {
			let b = utf8[i]
			if b != lt {
				out.append(b)
				i += 1
				continue
			}

			// Scan forward for `>` or end of input.
			var j = i + 1
			while j < count && utf8[j] != gt {
				j += 1
			}

			// Empty tag body — emit nothing, skip the `<`, let the
			// next iteration handle any trailing `>` as literal text.
			let tagStart = i + 1
			let tagEnd = j
			if tagStart == tagEnd {
				i += 1
				continue
			}

			// Extract the tag name: skip a leading `/` (closing tags),
			// then take the run of ASCII letters up to the first
			// non-letter (space, `/`, digit, quote). Attributes are
			// ignored, so `<abbr title="…">` is recognized as `abbr`.
			var nameStart = tagStart
			if nameStart < tagEnd && utf8[nameStart] == slash {
				nameStart += 1
			}
			var nameEnd = nameStart
			while nameEnd < tagEnd && Self.isASCIILetter(utf8[nameEnd]) {
				nameEnd += 1
			}
			let tagName = Array(utf8[nameStart..<nameEnd])
			let isAllowed = allowedTagsBytes.contains(tagName)

			// Only emit a closing `>` if the input actually had one. An
			// unclosed tag (no `>` before end of input) must not gain a
			// synthesized `>` — otherwise a title like `<16s in UK…`
			// renders with a spurious trailing `>` (issue #4742).
			let tagWasClosed = j < count

			if isAllowed {
				if forHTML {
					out.append(lt)
					out.append(contentsOf: utf8[tagStart..<tagEnd])
					if tagWasClosed {
						out.append(gt)
					}
				}
			} else {
				if forHTML {
					out.append(contentsOf: ltEntity)
					out.append(contentsOf: utf8[tagStart..<tagEnd])
					if tagWasClosed {
						out.append(contentsOf: gtEntity)
					}
				} else {
					out.append(lt)
					out.append(contentsOf: utf8[tagStart..<tagEnd])
					if tagWasClosed {
						out.append(gt)
					}
				}
			}

			i = tagWasClosed ? j + 1 : count
		}

		return String(decoding: out, as: UTF8.self)
	}
}

private extension ArticleTitleSanitizer {

	// UTF-8 byte arrays so tag-name lookup in `sanitizedTitle` stays
	// byte-level — no String allocation per tag.
	static let allowedTagsBytes: Set<[UInt8]> = {
		let names = ["abbr", "b", "bdi", "bdo", "cite", "code", "del", "dfn",
		             "em", "i", "ins", "kbd", "mark", "q", "s", "samp", "small",
		             "strong", "sub", "sup", "time", "u", "var"]
		return Set(names.map { Array($0.utf8) })
	}()

	static func isASCIILetter(_ byte: UInt8) -> Bool {
		(byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
	}
}
