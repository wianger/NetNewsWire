//
//  FMDBCompatibilityTests.swift
//  RSDatabaseTests
//
//  Covers the FMDB behavior NetNewsWire relies on. On Apple platforms these run against
//  Objective-C FMDB; elsewhere against the Swift FMDB in Sources/RSDatabase/SwiftFMDB —
//  so passing on both means the two behave the same.
//

import Foundation
import Testing
import RSDatabase
#if canImport(RSDatabaseObjC)
import RSDatabaseObjC
#endif

@Suite("FMDB compatibility")
struct FMDBCompatibilityTests {

	private func makeDatabase() throws -> FMDatabase {
		let database = try #require(FMDatabase(path: ":memory:"))
		#expect(database.open())
		#expect(database.executeStatements("create table items (id integer primary key, name text, payload blob, created double, flag integer, score double);"))
		return database
	}

	// MARK: - Binding and reading values

	@Test func bindsAndReadsValuesTheWayFMDBDoes() throws {
		let database = try makeDatabase()
		let date = Date(timeIntervalSince1970: 1_700_000_000.5)
		let payload = Data([0x00, 0x01, 0xFF])

		#expect(database.executeUpdate("insert into items (id, name, payload, created, flag, score) values (?, ?, ?, ?, ?, ?)", withArgumentsIn: [1, "Ünïcödé 中文", payload, date, true, 2.5]))

		let resultSet = try #require(database.executeQuery("select * from items where id = ?", withArgumentsIn: [1]))
		#expect(resultSet.next())
		#expect(resultSet.long(forColumn: "id") == 1)
		#expect(resultSet.string(forColumn: "name") == "Ünïcödé 中文")
		#expect(resultSet.data(forColumn: "payload") == payload)
		#expect(resultSet.date(forColumn: "created") == date)
		#expect(resultSet.double(forColumn: "created") == date.timeIntervalSince1970)
		#expect(resultSet.bool(forColumn: "flag"))
		#expect(resultSet.int(forColumn: "flag") == 1)
		#expect(resultSet.double(forColumn: "score") == 2.5)
		#expect((resultSet.object(forColumnName: "id") as? NSNumber)?.int64Value == 1)
		#expect(resultSet.object(forColumnName: "name") as? String == "Ünïcödé 中文")
		#expect(!resultSet.next())
		resultSet.close()
	}

	@Test func bindsNilAndNSNullAsNull() throws {
		let database = try makeDatabase()
		let missingName: String? = nil
		#expect(database.executeUpdate("insert into items (id, name, payload) values (?, ?, ?)", withArgumentsIn: [1, missingName as Any, NSNull()]))

		let resultSet = try #require(database.executeQuery("select name, payload from items", withArgumentsIn: []))
		#expect(resultSet.next())
		#expect(resultSet.columnIsNull("name"))
		#expect(resultSet.columnIsNull("payload"))
		#expect(resultSet.string(forColumn: "name") == nil)
		#expect(resultSet.data(forColumn: "payload") == nil)
		#expect(resultSet.date(forColumn: "created") == nil)
		#expect(resultSet.object(forColumnName: "name") is NSNull)
		resultSet.close()
	}

	@Test func emptyDataIsAnEmptyBlobNotNull() throws {
		let database = try makeDatabase()
		#expect(database.executeUpdate("insert into items (id, payload) values (?, ?)", withArgumentsIn: [1, Data()]))

		let resultSet = try #require(database.executeQuery("select payload, typeof(payload) as type from items", withArgumentsIn: []))
		#expect(resultSet.next())
		#expect(resultSet.string(forColumn: "type") == "blob")
		resultSet.close()
	}

	@Test func columnNamesAreCaseInsensitive() throws {
		let database = try makeDatabase()
		#expect(database.executeUpdate("insert into items (id, name) values (?, ?)", withArgumentsIn: [1, "a"]))

		let resultSet = try #require(database.executeQuery("select ID, Name from items", withArgumentsIn: []))
		#expect(resultSet.next())
		#expect(resultSet.long(forColumn: "id") == 1)
		#expect(resultSet.string(forColumn: "NAME") == "a")
		#expect(resultSet.columnIndex(forName: "name") == 1)
		#expect(resultSet.columnIndex(forName: "missing") == -1)
		resultSet.close()
	}

	// MARK: - Statement results

	@Test func reportsChangesAndLastInsertRowID() throws {
		let database = try makeDatabase()
		#expect(database.executeUpdate("insert into items (name) values (?)", withArgumentsIn: ["a"]))
		#expect(database.lastInsertRowId() == 1)
		#expect(database.executeUpdate("insert into items (name) values (?)", withArgumentsIn: ["b"]))
		#expect(database.lastInsertRowId() == 2)
		#expect(database.executeUpdate("update items set flag = 1", withArgumentsIn: []))
		#expect(database.changes() == 2)
	}

	@Test func failedStatementReturnsFalseAndSetsError() throws {
		let database = try makeDatabase()
		#expect(database.executeUpdate("insert into items (id) values (?)", withArgumentsIn: [1]))
		#expect(!database.executeUpdate("insert into items (id) values (?)", withArgumentsIn: [1]))
		#expect(database.hadError())
		#expect(database.lastErrorCode() == 19) // SQLITE_CONSTRAINT
		#expect(database.executeQuery("select * from no_such_table", withArgumentsIn: []) == nil)
	}

	@Test func tableAndColumnExistence() throws {
		let database = try makeDatabase()
		#expect(database.tableExists("items"))
		#expect(database.tableExists("ITEMS"))
		#expect(!database.tableExists("nothing"))
		#expect(database.columnExists("name", inTableWithName: "items"))
		#expect(!database.columnExists("nothing", inTableWithName: "items"))
	}

	@Test func rollbackDiscardsChanges() throws {
		let database = try makeDatabase()
		#expect(database.beginTransaction())
		#expect(database.executeUpdate("insert into items (id) values (?)", withArgumentsIn: [1]))
		#expect(database.rollback())
		#expect(database.rs_tableIsEmpty("items"))

		#expect(database.beginTransaction())
		#expect(database.executeUpdate("insert into items (id) values (?)", withArgumentsIn: [1]))
		#expect(database.commit())
		#expect(!database.rs_tableIsEmpty("items"))
	}

	@Test func cachedStatementsCanBeReused() throws {
		let database = try makeDatabase()
		database.setShouldCacheStatements(true)
		for i in 1...5 {
			#expect(database.executeUpdate("insert into items (id, name) values (?, ?)", withArgumentsIn: [i, "item \(i)"]))
		}
		for i in 1...5 {
			let resultSet = try #require(database.executeQuery("select name from items where id = ?", withArgumentsIn: [i]))
			#expect(resultSet.next())
			#expect(resultSet.string(forColumn: "name") == "item \(i)")
			resultSet.close()
		}
	}

	// MARK: - RSExtras

	@Test func insertUpdateSelectAndDeleteHelpers() throws {
		let database = try makeDatabase()
		#expect(database.rs_insertRow(with: ["id": 1, "name": "a"], insertType: .normal, tableName: "items"))
		#expect(database.rs_insertRow(with: ["id": 2, "name": "b"], insertType: .normal, tableName: "items"))
		#expect(database.rs_insertRow(with: ["id": 1, "name": "ignored"], insertType: .orIgnore, tableName: "items"))
		#expect(database.rs_insertRow(with: ["id": 2, "name": "replaced"], insertType: .orReplace, tableName: "items"))
		#expect(database.rs_rowExistsWithValue("replaced", forKey: "name", tableName: "items"))
		#expect(!database.rs_rowExistsWithValue("ignored", forKey: "name", tableName: "items"))

		#expect(database.rs_updateRows(with: ["flag": 1], whereKey: "id", inValues: [1, 2], tableName: "items"))
		let resultSet = try #require(database.rs_selectRowsWhereKey("id", inValues: [1, 2], tableName: "items"))
		var count = 0
		while resultSet.next() {
			#expect(resultSet.bool(forColumn: "flag"))
			count += 1
		}
		#expect(count == 2)

		#expect(database.rs_deleteRowsWhereKey("id", inValues: [1], tableName: "items"))
		#expect(!database.rs_rowExistsWithValue(1, forKey: "id", tableName: "items"))
		#expect(database.rs_deleteRowsWhereKey("id", inValues: [], tableName: "items"))
		#expect(!database.rs_tableIsEmpty("items"))
	}

	// MARK: - SQLite features

	@Test func fullTextSearchIsAvailable() throws {
		// Article search uses FTS4; the SQLite built for non-Apple platforms must include it.
		let database = try makeDatabase()
		#expect(database.executeStatements("create virtual table search using fts4(title, body);"))
		#expect(database.executeUpdate("insert into search (title, body) values (?, ?)", withArgumentsIn: ["Hello", "NetNewsWire on Windows"]))

		let resultSet = try #require(database.executeQuery("select title from search where search match ?", withArgumentsIn: ["windows"]))
		#expect(resultSet.next())
		#expect(resultSet.string(forColumn: "title") == "Hello")
		resultSet.close()
	}
}
