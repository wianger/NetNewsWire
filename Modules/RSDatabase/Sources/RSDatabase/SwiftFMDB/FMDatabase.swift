//
//  FMDatabase.swift
//  RSDatabase
//
//  A pure Swift implementation of the subset of FMDB that NetNewsWire uses,
//  for platforms without the Objective-C runtime (Windows, Linux).
//  On Apple platforms the Objective-C FMDB in RSDatabaseObjC is used instead.
//
//  Names, signatures and semantics match FMDB so that callers compile unchanged:
//  - values bind the way FMDB binds them (Date as timeIntervalSince1970, Bool as 0/1,
//    nil/NSNull as NULL, Data as BLOB, everything else as its description);
//  - column names are matched case-insensitively;
//  - failures return false/nil and are logged, never thrown.
//

#if !canImport(RSDatabaseObjC)

import Foundation
import CSQLite
#if canImport(os)
import os
#else
import RSCore
#endif

/// `@unchecked Sendable`: like FMDB, an FMDatabase must only be used from one thread at a time
/// (DatabaseQueue enforces this with a serial queue).
public final class FMDatabase: @unchecked Sendable {

	private static let logger = Logger(subsystem: logSubsystem, category: "SwiftFMDB")

	private let path: String?
	private(set) var handle: OpaquePointer?
	private var shouldCacheStatements = false
	private var cachedStatements = [String: CachedStatement]()

	public init?(path: String?) {
		self.path = path
	}

	deinit {
		close()
	}

	public var isOpen: Bool {
		handle != nil
	}

	public func databasePath() -> String? {
		path
	}

	// MARK: - Opening and Closing

	@discardableResult
	public func open() -> Bool {
		if handle != nil {
			return true
		}
		var db: OpaquePointer?
		let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
		let result = sqlite3_open_v2(path ?? ":memory:", &db, flags, nil)
		guard result == SQLITE_OK, let db else {
			Self.logger.error("Could not open database \(self.path ?? ":memory:", privacy: .public): SQLite \(result, privacy: .public)")
			sqlite3_close(db)
			return false
		}
		handle = db
		// FMDB retries on SQLITE_BUSY; a busy timeout gives the same effect.
		sqlite3_busy_timeout(db, 2000)
		return true
	}

	@discardableResult
	public func close() -> Bool {
		guard let handle else {
			return true
		}
		for statement in cachedStatements.values {
			statement.finalize()
		}
		cachedStatements.removeAll()
		let result = sqlite3_close_v2(handle)
		self.handle = nil
		return result == SQLITE_OK
	}

	public func setShouldCacheStatements(_ value: Bool) {
		shouldCacheStatements = value
		if !value {
			for statement in cachedStatements.values {
				statement.finalize()
			}
			cachedStatements.removeAll()
		}
	}

	// MARK: - Executing

	/// Runs one or more SQL statements separated by semicolons, without arguments.
	@discardableResult
	public func executeStatements(_ sql: String) -> Bool {
		guard let handle else {
			logNotOpen(sql)
			return false
		}
		var errorMessage: UnsafeMutablePointer<CChar>?
		let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
		if result != SQLITE_OK {
			let message = errorMessage.map { String(cString: $0) } ?? "unknown"
			Self.logger.error("executeStatements failed — SQLite \(result, privacy: .public): \(message, privacy: .public) — \(sql, privacy: .public)")
		}
		sqlite3_free(errorMessage)
		return result == SQLITE_OK
	}

	@discardableResult
	public func executeUpdate(_ sql: String, withArgumentsIn arguments: [Any]? = nil) -> Bool {
		guard let statement = prepare(sql, arguments: arguments ?? []) else {
			return false
		}
		defer {
			statement.reset()
		}
		let result = sqlite3_step(statement.pointer)
		// Like FMDB: one step, and a statement that returns rows is a programming error.
		assert(result != SQLITE_ROW, "executeUpdate called with a query: \(sql)")
		if result != SQLITE_DONE {
			logError(sql)
			return false
		}
		return true
	}

	public func executeQuery(_ sql: String, withArgumentsIn arguments: [Any]? = nil) -> FMResultSet? {
		guard let statement = prepare(sql, arguments: arguments ?? []) else {
			return nil
		}
		return FMResultSet(statement: statement, database: self, sql: sql)
	}

	// MARK: - Transactions

	@discardableResult
	public func beginTransaction() -> Bool {
		executeStatements("begin exclusive transaction")
	}

	@discardableResult
	public func commit() -> Bool {
		executeStatements("commit transaction")
	}

	@discardableResult
	public func rollback() -> Bool {
		executeStatements("rollback transaction")
	}

	// MARK: - Information

	public func lastErrorMessage() -> String? {
		guard let handle, let message = sqlite3_errmsg(handle) else {
			return nil
		}
		return String(cString: message)
	}

	public func lastErrorCode() -> Int32 {
		guard let handle else {
			return SQLITE_MISUSE
		}
		return sqlite3_errcode(handle)
	}

	public func hadError() -> Bool {
		let code = lastErrorCode()
		return code > SQLITE_OK && code < SQLITE_ROW
	}

	public func changes() -> Int32 {
		guard let handle else {
			return 0
		}
		return sqlite3_changes(handle)
	}

	public func lastInsertRowId() -> Int64 {
		guard let handle else {
			return 0
		}
		return sqlite3_last_insert_rowid(handle)
	}

	public func tableExists(_ tableName: String) -> Bool {
		guard let resultSet = executeQuery("select [sql] from sqlite_master where [type] = 'table' and lower(name) = ?", withArgumentsIn: [tableName.lowercased()]) else {
			return false
		}
		defer {
			resultSet.close()
		}
		return resultSet.next()
	}

	public func columnExists(_ columnName: String, inTableWithName tableName: String) -> Bool {
		guard let resultSet = executeQuery("pragma table_info('\(tableName.replacingOccurrences(of: "'", with: "''"))')") else {
			return false
		}
		defer {
			resultSet.close()
		}
		let name = columnName.lowercased()
		while resultSet.next() {
			if resultSet.string(forColumn: "name")?.lowercased() == name {
				return true
			}
		}
		return false
	}
}

// MARK: - Statements

final class CachedStatement {

	let pointer: OpaquePointer
	var inUse = false
	private var isFinalized = false

	init(pointer: OpaquePointer) {
		self.pointer = pointer
	}

	func reset() {
		sqlite3_reset(pointer)
		sqlite3_clear_bindings(pointer)
		inUse = false
	}

	func finalize() {
		guard !isFinalized else {
			return
		}
		isFinalized = true
		sqlite3_finalize(pointer)
	}
}

extension FMDatabase {

	func statementDidClose(_ statement: CachedStatement, sql: String) {
		statement.reset()
		if !shouldCacheStatements || cachedStatements[sql] !== statement {
			statement.finalize()
		}
	}

	private func prepare(_ sql: String, arguments: [Any]) -> CachedStatement? {
		guard let handle else {
			logNotOpen(sql)
			return nil
		}

		let statement: CachedStatement
		if shouldCacheStatements, let cached = cachedStatements[sql], !cached.inUse {
			statement = cached
		} else {
			var pointer: OpaquePointer?
			guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
				logError(sql)
				sqlite3_finalize(pointer)
				return nil
			}
			statement = CachedStatement(pointer: pointer)
			if shouldCacheStatements && cachedStatements[sql] == nil {
				cachedStatements[sql] = statement
			}
		}
		statement.inUse = true

		let parameterCount = Int(sqlite3_bind_parameter_count(statement.pointer))
		guard parameterCount == arguments.count else {
			Self.logger.error("Wrong number of arguments: expected \(parameterCount, privacy: .public), got \(arguments.count, privacy: .public) — \(sql, privacy: .public)")
			statementDidClose(statement, sql: sql)
			return nil
		}
		for (index, argument) in arguments.enumerated() {
			bind(argument, at: Int32(index + 1), in: statement.pointer)
		}
		return statement
	}

	private func bind(_ value: Any, at index: Int32, in statement: OpaquePointer) {
		guard let value = unwrapOptional(value) else {
			sqlite3_bind_null(statement, index)
			return
		}
		switch value {
		case is NSNull:
			sqlite3_bind_null(statement, index)
		case let data as Data:
			data.withUnsafeBytes { buffer in
				// An empty blob must not get a NULL pointer, or SQLite binds NULL instead.
				let bytes = buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)
				sqlite3_bind_blob(statement, index, bytes, Int32(buffer.count), SQLITE_TRANSIENT)
			}
		case let date as Date:
			sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
		case let bool as Bool:
			sqlite3_bind_int(statement, index, bool ? 1 : 0)
		case let int as Int:
			sqlite3_bind_int64(statement, index, Int64(int))
		case let int as Int64:
			sqlite3_bind_int64(statement, index, int)
		case let int as Int32:
			sqlite3_bind_int(statement, index, int)
		case let int as Int16:
			sqlite3_bind_int(statement, index, Int32(int))
		case let int as Int8:
			sqlite3_bind_int(statement, index, Int32(int))
		case let int as UInt:
			sqlite3_bind_int64(statement, index, Int64(bitPattern: UInt64(int)))
		case let int as UInt64:
			sqlite3_bind_int64(statement, index, Int64(bitPattern: int))
		case let int as UInt32:
			sqlite3_bind_int64(statement, index, Int64(int))
		case let int as UInt16:
			sqlite3_bind_int(statement, index, Int32(int))
		case let int as UInt8:
			sqlite3_bind_int(statement, index, Int32(int))
		case let double as Double:
			sqlite3_bind_double(statement, index, double)
		case let float as Float:
			sqlite3_bind_double(statement, index, Double(float))
		case let number as NSNumber:
			bindNumber(number, at: index, in: statement)
		case let string as String:
			sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
		default:
			sqlite3_bind_text(statement, index, String(describing: value), -1, SQLITE_TRANSIENT)
		}
	}

	private func bindNumber(_ number: NSNumber, at index: Int32, in statement: OpaquePointer) {
		switch String(cString: number.objCType) {
		case "f", "d":
			sqlite3_bind_double(statement, index, number.doubleValue)
		case "B", "c":
			sqlite3_bind_int(statement, index, number.boolValue ? 1 : 0)
		default:
			sqlite3_bind_int64(statement, index, number.int64Value)
		}
	}

	private func unwrapOptional(_ value: Any) -> Any? {
		let mirror = Mirror(reflecting: value)
		guard mirror.displayStyle == .optional else {
			return value
		}
		guard let wrapped = mirror.children.first?.value else {
			return nil
		}
		return unwrapOptional(wrapped)
	}

	private func logError(_ sql: String) {
		Self.logger.error("SQLite \(self.lastErrorCode(), privacy: .public): \(self.lastErrorMessage() ?? "unknown", privacy: .public) — \(sql, privacy: .public)")
	}

	private func logNotOpen(_ sql: String) {
		Self.logger.error("Database \(self.path ?? ":memory:", privacy: .public) is not open — \(sql, privacy: .public)")
	}
}

/// Equivalent of SQLITE_TRANSIENT, which the C macro form does not import into Swift.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

#endif
