//
//  FMDatabase+RSExtras.swift
//  RSDatabase
//
//  Swift port of FMDatabase+RSExtras.m and NSString+RSDatabase.m for platforms
//  without Objective-C FMDB. Generates the same SQL as the Objective-C versions.
//

#if !canImport(RSDatabaseObjC)

import Foundation

public enum RSDatabaseInsertType: Int, Sendable {
	case normal
	case orReplace
	case orIgnore
}

public extension FMDatabase {

	// MARK: - Deleting

	@discardableResult
	func rs_deleteRowsWhereKey(_ key: String, inValues values: [Any], tableName: String) -> Bool {
		if values.isEmpty {
			return true
		}
		let sql = "delete from \(tableName) where \(key) in \(NSString.rs_SQLValueList(withPlaceholders: UInt(values.count)))"
		return executeUpdate(sql, withArgumentsIn: values)
	}

	@discardableResult
	func rs_deleteRowsWhereKey(_ key: String, equalsValue value: Any, tableName: String) -> Bool {
		executeUpdate("delete from \(tableName) where \(key) = ?", withArgumentsIn: [value])
	}

	// MARK: - Selecting

	func rs_selectRowsWhereKey(_ key: String, inValues values: [Any], tableName: String) -> FMResultSet? {
		let sql = "select * from \(tableName) where \(key) in \(NSString.rs_SQLValueList(withPlaceholders: UInt(values.count)))"
		return executeQuery(sql, withArgumentsIn: values)
	}

	func rs_selectRowsWhereKey(_ key: String, equalsValue value: Any, tableName: String) -> FMResultSet? {
		executeQuery("select * from \(tableName) where \(key) = ?", withArgumentsIn: [value])
	}

	func rs_selectSingleRowWhereKey(_ key: String, equalsValue value: Any, tableName: String) -> FMResultSet? {
		executeQuery("select * from \(tableName) where \(key) = ? limit 1", withArgumentsIn: [value])
	}

	func rs_selectAllRows(_ tableName: String) -> FMResultSet? {
		executeQuery("select * from \(tableName)")
	}

	func rs_selectColumn(withKey key: String, tableName: String) -> FMResultSet? {
		executeQuery("select \(key) from \(tableName)")
	}

	/// Named as Swift imports the Objective-C `rs_rowExistsWithValue:forKey:tableName:`, which Apple platforms use.
	func rs_rowExists(withValue value: Any, forKey key: String, tableName: String) -> Bool {
		guard let resultSet = executeQuery("select 1 from \(tableName) where \(key) = ? limit 1;", withArgumentsIn: [value]) else {
			return false
		}
		defer {
			resultSet.close()
		}
		return resultSet.next()
	}

	func rs_tableIsEmpty(_ tableName: String) -> Bool {
		guard let resultSet = executeQuery("select 1 from \(tableName) limit 1;") else {
			return true
		}
		defer {
			resultSet.close()
		}
		return !resultSet.next()
	}

	// MARK: - Updating

	@discardableResult
	func rs_updateRows(with dictionary: [String: Any], whereKey key: String, equalsValue value: Any, tableName: String) -> Bool {
		rs_updateRows(with: dictionary, whereKey: key, inValues: [value], tableName: tableName)
	}

	@discardableResult
	func rs_updateRows(with dictionary: [String: Any], whereKey key: String, inValues keyValues: [Any], tableName: String) -> Bool {
		let keys = Array(dictionary.keys)
		let values = keys.map { dictionary[$0] as Any }
		let sql = "update \(tableName) set \(NSString.rs_SQLKeyPlaceholderPairs(withKeys: keys)) where \(key) in \(NSString.rs_SQLValueList(withPlaceholders: UInt(keyValues.count)))"
		return executeUpdate(sql, withArgumentsIn: values + keyValues)
	}

	@discardableResult
	func rs_updateRows(withValue value: Any, valueKey: String, whereKey key: String, inValues keyValues: [Any], tableName: String) -> Bool {
		rs_updateRows(with: [valueKey: value], whereKey: key, inValues: keyValues, tableName: tableName)
	}

	// MARK: - Saving

	@discardableResult
	func rs_insertRow(with dictionary: [String: Any], insertType: RSDatabaseInsertType, tableName: String) -> Bool {
		let keys = Array(dictionary.keys)
		let values = keys.map { dictionary[$0] as Any }
		let sqlBeginning = switch insertType {
		case .normal: "insert into "
		case .orReplace: "insert or replace into "
		case .orIgnore: "insert or ignore into "
		}
		let sql = "\(sqlBeginning) \(tableName) \(NSString.rs_SQLKeysList(with: keys)) values \(NSString.rs_SQLValueList(withPlaceholders: UInt(values.count)))"
		return executeUpdate(sql, withArgumentsIn: values)
	}
}

public extension NSString {

	/// Returns "(?, ?, ?)" with `numberOfValues` placeholders, or "()" — which SQLite accepts
	/// and which matches nothing — when `numberOfValues` is less than one.
	static func rs_SQLValueList(withPlaceholders numberOfValues: UInt) -> String {
		guard numberOfValues > 0 else {
			return "()"
		}
		return "(" + Array(repeating: "?", count: Int(numberOfValues)).joined(separator: ", ") + ")"
	}

	/// Returns "(someColumn, anotherColumn)". Keys must be trusted — never user input.
	static func rs_SQLKeysList(with keys: [String]) -> String {
		"(" + keys.joined(separator: ", ") + ")"
	}

	/// Returns "key1=?, key2=?". Keys must be trusted — never user input.
	static func rs_SQLKeyPlaceholderPairs(withKeys keys: [String]) -> String {
		keys.map { "\($0)=?" }.joined(separator: ", ")
	}
}

#endif
