//
//  FMResultSet.swift
//  RSDatabase
//
//  Pure Swift FMResultSet for platforms without Objective-C FMDB. See FMDatabase.swift.
//

#if !canImport(RSDatabaseObjC)

import Foundation
import CSQLite

public final class FMResultSet: @unchecked Sendable {

	private var statement: CachedStatement?
	private let database: FMDatabase
	private let sql: String
	private var columnIndexes: [String: Int32]?

	init(statement: CachedStatement, database: FMDatabase, sql: String) {
		self.statement = statement
		self.database = database
		self.sql = sql
	}

	deinit {
		close()
	}

	public func next() -> Bool {
		guard let statement else {
			return false
		}
		let result = sqlite3_step(statement.pointer)
		if result == SQLITE_ROW {
			return true
		}
		close()
		return false
	}

	public func close() {
		guard let statement else {
			return
		}
		self.statement = nil
		database.statementDidClose(statement, sql: sql)
	}

	/// Lowercased column names to indexes.
	public var columnNameToIndexMap: [String: Int32]? {
		if let columnIndexes {
			return columnIndexes
		}
		guard let pointer = statement?.pointer else {
			return nil
		}
		var map = [String: Int32]()
		for index in 0..<sqlite3_column_count(pointer) {
			if let name = sqlite3_column_name(pointer, index) {
				map[String(cString: name).lowercased()] = index
			}
		}
		columnIndexes = map
		return map
	}

	public func columnIndex(forName columnName: String) -> Int32 {
		columnNameToIndexMap?[columnName.lowercased()] ?? -1
	}

	// MARK: - Values by column index

	public func columnIsNull(_ columnName: String) -> Bool {
		columnIsNull(forColumnIndex: columnIndex(forName: columnName))
	}

	public func columnIsNull(forColumnIndex index: Int32) -> Bool {
		guard let pointer = valid(index) else {
			return true
		}
		return sqlite3_column_type(pointer, index) == SQLITE_NULL
	}

	public func int(forColumnIndex index: Int32) -> Int32 {
		guard let pointer = valid(index) else {
			return 0
		}
		return sqlite3_column_int(pointer, index)
	}

	public func long(forColumnIndex index: Int32) -> Int {
		guard let pointer = valid(index) else {
			return 0
		}
		return Int(sqlite3_column_int64(pointer, index))
	}

	public func longLongInt(forColumnIndex index: Int32) -> Int64 {
		guard let pointer = valid(index) else {
			return 0
		}
		return sqlite3_column_int64(pointer, index)
	}

	public func bool(forColumnIndex index: Int32) -> Bool {
		int(forColumnIndex: index) != 0
	}

	public func double(forColumnIndex index: Int32) -> Double {
		guard let pointer = valid(index) else {
			return 0
		}
		return sqlite3_column_double(pointer, index)
	}

	public func string(forColumnIndex index: Int32) -> String? {
		guard let pointer = valid(index), sqlite3_column_type(pointer, index) != SQLITE_NULL, let text = sqlite3_column_text(pointer, index) else {
			return nil
		}
		let count = Int(sqlite3_column_bytes(pointer, index))
		return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
	}

	public func date(forColumnIndex index: Int32) -> Date? {
		guard let pointer = valid(index), sqlite3_column_type(pointer, index) != SQLITE_NULL else {
			return nil
		}
		return Date(timeIntervalSince1970: sqlite3_column_double(pointer, index))
	}

	public func data(forColumnIndex index: Int32) -> Data? {
		guard let pointer = valid(index), sqlite3_column_type(pointer, index) != SQLITE_NULL else {
			return nil
		}
		let count = Int(sqlite3_column_bytes(pointer, index))
		guard count > 0, let bytes = sqlite3_column_blob(pointer, index) else {
			return Data()
		}
		return Data(bytes: bytes, count: count)
	}

	/// Unlike FMDB, this copies: Foundation on non-Apple platforms has no cheap no-copy wrapper
	/// that is safe once SQLite moves to the next row.
	public func dataNoCopy(forColumnIndex index: Int32) -> Data? {
		data(forColumnIndex: index)
	}

	/// Like FMDB: NSNull for NULL, NSNumber for integers and doubles, String for text, Data for blobs.
	public func object(forColumnIndex index: Int32) -> Any? {
		guard let pointer = valid(index) else {
			return nil
		}
		switch sqlite3_column_type(pointer, index) {
		case SQLITE_INTEGER:
			return NSNumber(value: sqlite3_column_int64(pointer, index))
		case SQLITE_FLOAT:
			return NSNumber(value: sqlite3_column_double(pointer, index))
		case SQLITE_BLOB:
			return data(forColumnIndex: index)
		case SQLITE_NULL:
			return NSNull()
		default:
			return string(forColumnIndex: index)
		}
	}

	// MARK: - Values by column name

	public func object(forColumnName columnName: String) -> Any? {
		object(forColumnIndex: columnIndex(forName: columnName))
	}

	public func int(forColumn columnName: String) -> Int32 {
		int(forColumnIndex: columnIndex(forName: columnName))
	}

	public func long(forColumn columnName: String) -> Int {
		long(forColumnIndex: columnIndex(forName: columnName))
	}

	public func longLongInt(forColumn columnName: String) -> Int64 {
		longLongInt(forColumnIndex: columnIndex(forName: columnName))
	}

	public func bool(forColumn columnName: String) -> Bool {
		bool(forColumnIndex: columnIndex(forName: columnName))
	}

	public func double(forColumn columnName: String) -> Double {
		double(forColumnIndex: columnIndex(forName: columnName))
	}

	public func string(forColumn columnName: String) -> String? {
		string(forColumnIndex: columnIndex(forName: columnName))
	}

	public func date(forColumn columnName: String) -> Date? {
		date(forColumnIndex: columnIndex(forName: columnName))
	}

	public func data(forColumn columnName: String) -> Data? {
		data(forColumnIndex: columnIndex(forName: columnName))
	}

	public func dataNoCopy(forColumn columnName: String) -> Data? {
		dataNoCopy(forColumnIndex: columnIndex(forName: columnName))
	}

	// MARK: - Private

	private func valid(_ index: Int32) -> OpaquePointer? {
		guard index >= 0, let pointer = statement?.pointer, index < sqlite3_column_count(pointer) else {
			return nil
		}
		return pointer
	}
}

#endif
