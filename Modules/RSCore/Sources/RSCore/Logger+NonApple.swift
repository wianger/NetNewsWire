//
//  Logger+NonApple.swift
//  RSCore
//
//  A source-compatible stand-in for os.Logger on platforms without the os module
//  (Windows, Linux), so that shared code can log the same way everywhere.
//
//  Supports the subset of the os.Logger API used in NetNewsWire: the log levels,
//  string interpolation, and the `privacy:` interpolation parameter
//  (which is accepted and ignored — these logs stay on the device).
//
//  Hosts can redirect output by setting `Logger.sink` (the Windows app forwards
//  log records to its own logging).
//

#if !canImport(os)

import Foundation
import Synchronization
#if os(Windows)
import WinSDK
#endif

public enum OSLogType: Int, Sendable {
	case debug, info, `default`, error, fault

	public var name: String {
		switch self {
		case .debug: "debug"
		case .info: "info"
		case .default: "notice"
		case .error: "error"
		case .fault: "fault"
		}
	}
}

public struct OSLogPrivacy: Sendable {
	public static let auto = OSLogPrivacy()
	public static let `public` = OSLogPrivacy()
	public static let `private` = OSLogPrivacy()
	public static let sensitive = OSLogPrivacy()

	public static func `private`(mask: OSLogPrivacy.Mask) -> OSLogPrivacy {
		OSLogPrivacy()
	}

	public static func sensitive(mask: OSLogPrivacy.Mask) -> OSLogPrivacy {
		OSLogPrivacy()
	}

	public enum Mask: Sendable {
		case hash, none
	}
}

public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {

	public let text: String

	public init(stringLiteral value: String) {
		text = value
	}

	public init(stringInterpolation: StringInterpolation) {
		text = stringInterpolation.text
	}

	public struct StringInterpolation: StringInterpolationProtocol {

		var text = ""

		public init(literalCapacity: Int, interpolationCount: Int) {
			text.reserveCapacity(literalCapacity + interpolationCount * 8)
		}

		public mutating func appendLiteral(_ literal: String) {
			text += literal
		}

		public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: OSLogPrivacy = .auto) {
			text += String(describing: value())
		}

		public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T?, privacy: OSLogPrivacy = .auto) {
			if let value = value() {
				text += String(describing: value)
			} else {
				text += "nil"
			}
		}

		public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: @autoclosure () -> T, format: OSLogFloatFormatting, privacy: OSLogPrivacy = .auto) {
			text += format.string(for: Double(value()))
		}
	}
}

/// Subset of os.OSLogFloatFormatting used by NetNewsWire.
public struct OSLogFloatFormatting: Sendable {

	private let precision: Int?

	public static let fixed = OSLogFloatFormatting(precision: nil)

	public static func fixed(precision: Int) -> OSLogFloatFormatting {
		OSLogFloatFormatting(precision: precision)
	}

	func string(for value: Double) -> String {
		guard let precision else {
			return String(value)
		}
		return String(format: "%.\(precision)f", value)
	}
}

public struct Logger: Sendable {

	public struct Record: Sendable {
		public let level: OSLogType
		public let subsystem: String
		public let category: String
		public let message: String
	}

	public typealias Sink = @Sendable (Record) -> Void

	private static let currentSink = Mutex<Sink>(Logger.defaultSink)

	/// Where log records go. Defaults to standard error (and the debugger on Windows).
	public static var sink: Sink {
		get { currentSink.withLock { $0 } }
		set { currentSink.withLock { $0 = newValue } }
	}

	public let subsystem: String
	public let category: String

	public init(subsystem: String, category: String) {
		self.subsystem = subsystem
		self.category = category
	}

	public func log(level: OSLogType, _ message: OSLogMessage) {
		Logger.sink(Record(level: level, subsystem: subsystem, category: category, message: message.text))
	}

	public func log(_ message: OSLogMessage) {
		log(level: .default, message)
	}

	public func trace(_ message: OSLogMessage) {
		log(level: .debug, message)
	}

	public func debug(_ message: OSLogMessage) {
		log(level: .debug, message)
	}

	public func info(_ message: OSLogMessage) {
		log(level: .info, message)
	}

	public func notice(_ message: OSLogMessage) {
		log(level: .default, message)
	}

	public func warning(_ message: OSLogMessage) {
		log(level: .error, message)
	}

	public func error(_ message: OSLogMessage) {
		log(level: .error, message)
	}

	public func critical(_ message: OSLogMessage) {
		log(level: .fault, message)
	}

	public func fault(_ message: OSLogMessage) {
		log(level: .fault, message)
	}

	private static let defaultSink: Sink = { record in
		let line = "[\(record.level.name)] \(record.category): \(record.message)\n"
		#if os(Windows)
		line.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
		#endif
		// The throwing write: the legacy write(_:) traps when stderr is missing, as it is
		// in a Windows GUI app started without a console. Logging must never crash the app.
		try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
	}
}

// MARK: - OSSignposter

/// Signposts appear in Instruments on Apple platforms. Elsewhere they are accepted and
/// dropped; a Windows backend could emit ETW TraceLogging events instead.
public struct OSSignposter: Sendable {

	public enum Category: Sendable {
		case pointsOfInterest
		case dynamicTracing
		case dynamicStackTracing
	}

	public init(subsystem: String, category: Category) {
	}

	public init(subsystem: String, category: String) {
	}

	public func beginInterval(_ name: StaticString, _ message: OSLogMessage = "") -> OSSignpostIntervalState {
		OSSignpostIntervalState()
	}

	public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState, _ message: OSLogMessage = "") {
	}

	public func emitEvent(_ name: StaticString, _ message: OSLogMessage = "") {
	}
}

public struct OSSignpostIntervalState: Sendable {
}

#endif
