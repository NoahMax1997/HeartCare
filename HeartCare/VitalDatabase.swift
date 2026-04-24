import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class VitalDatabase {
    private var db: OpaquePointer?

    init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = documents.appendingPathComponent("vitaltrack.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw DatabaseError.openFailed
        }
        try createTablesIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    func fetchMinuteRecords() throws -> [VitalMinuteRecord] {
        let sql = """
        SELECT timestamp_minute, heart_rate_avg, heart_rate_min, heart_rate_max, resp_rate_avg, sample_count, source, quality_flag
        FROM vitals_minute
        ORDER BY timestamp_minute DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var results: [VitalMinuteRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = dateFromUnix(sqlite3_column_double(statement, 0))
            let record = VitalMinuteRecord(
                timestampMinute: timestamp,
                heartRateAvg: valueOrNil(statement, index: 1),
                heartRateMin: valueOrNil(statement, index: 2),
                heartRateMax: valueOrNil(statement, index: 3),
                respiratoryRateAvg: valueOrNil(statement, index: 4),
                sampleCount: Int(sqlite3_column_int(statement, 5)),
                source: stringValue(statement, index: 6),
                qualityFlag: stringValue(statement, index: 7)
            )
            results.append(record)
        }
        return results
    }

    func upsertMinuteRecords(_ records: [MinuteAggregate]) throws {
        let sql = """
        INSERT INTO vitals_minute
        (timestamp_minute, heart_rate_avg, heart_rate_min, heart_rate_max, resp_rate_avg, sample_count, source, quality_flag)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(timestamp_minute) DO UPDATE SET
          heart_rate_avg = excluded.heart_rate_avg,
          heart_rate_min = excluded.heart_rate_min,
          heart_rate_max = excluded.heart_rate_max,
          resp_rate_avg = excluded.resp_rate_avg,
          sample_count = excluded.sample_count,
          source = excluded.source,
          quality_flag = excluded.quality_flag;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        try beginTransaction()
        for record in records {
            sqlite3_reset(statement)
            bindDate(statement, index: 1, date: record.timestampMinute)
            bindNullableDouble(statement, index: 2, value: record.heartRateAvg)
            bindNullableDouble(statement, index: 3, value: record.heartRateMin)
            bindNullableDouble(statement, index: 4, value: record.heartRateMax)
            bindNullableDouble(statement, index: 5, value: record.respiratoryRateAvg)
            sqlite3_bind_int(statement, 6, Int32(record.sampleCount))
            sqlite3_bind_text(statement, 7, record.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 8, record.qualityFlag, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                try rollbackTransaction()
                throw DatabaseError.writeFailed
            }
        }
        try commitTransaction()
    }

    func insertRawSamples(_ samples: [VitalSample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let sql = """
        INSERT INTO raw_samples (timestamp, value, kind, source)
        VALUES (?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var insertedCount = 0
        try beginTransaction()
        for sample in samples {
            sqlite3_reset(statement)
            bindDate(statement, index: 1, date: sample.timestamp)
            sqlite3_bind_double(statement, 2, sample.value)
            sqlite3_bind_text(statement, 3, sample.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, sample.source, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                try rollbackTransaction()
                throw DatabaseError.writeFailed
            }
            insertedCount += Int(sqlite3_changes(db))
        }
        try commitTransaction()
        return insertedCount
    }

    func insertRawSamplesDeduplicated(_ samples: [VitalSample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let sql = """
        INSERT INTO raw_samples (timestamp, value, kind, source)
        SELECT ?, ?, ?, ?
        WHERE NOT EXISTS (
            SELECT 1
            FROM raw_samples
            WHERE timestamp = ?
              AND value = ?
              AND kind = ?
              AND source = ?
        );
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var insertedCount = 0
        try beginTransaction()
        for sample in samples {
            sqlite3_reset(statement)
            let timestamp = sample.timestamp.timeIntervalSince1970
            sqlite3_bind_double(statement, 1, timestamp)
            sqlite3_bind_double(statement, 2, sample.value)
            sqlite3_bind_text(statement, 3, sample.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, sample.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 5, timestamp)
            sqlite3_bind_double(statement, 6, sample.value)
            sqlite3_bind_text(statement, 7, sample.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 8, sample.source, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                try rollbackTransaction()
                throw DatabaseError.writeFailed
            }
            insertedCount += Int(sqlite3_changes(db))
        }
        try commitTransaction()
        return insertedCount
    }
    
    func insertRawSamplesDeduplicatedIgnoringSource(_ samples: [VitalSample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let sql = """
        INSERT INTO raw_samples (timestamp, value, kind, source)
        SELECT ?, ?, ?, ?
        WHERE NOT EXISTS (
            SELECT 1
            FROM raw_samples
            WHERE timestamp = ?
              AND value = ?
              AND kind = ?
        );
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        
        var insertedCount = 0
        try beginTransaction()
        for sample in samples {
            sqlite3_reset(statement)
            let timestamp = sample.timestamp.timeIntervalSince1970
            sqlite3_bind_double(statement, 1, timestamp)
            sqlite3_bind_double(statement, 2, sample.value)
            sqlite3_bind_text(statement, 3, sample.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, sample.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 5, timestamp)
            sqlite3_bind_double(statement, 6, sample.value)
            sqlite3_bind_text(statement, 7, sample.kind.rawValue, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                try rollbackTransaction()
                throw DatabaseError.writeFailed
            }
            insertedCount += Int(sqlite3_changes(db))
        }
        try commitTransaction()
        return insertedCount
    }

    func deleteRawSamples(kind: VitalSample.Kind) throws {
        let sql = "DELETE FROM raw_samples WHERE kind = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.writeFailed
        }
    }

    func deleteRawSamples(kind: VitalSample.Kind, since: Date) throws {
        let sql = "DELETE FROM raw_samples WHERE kind = ? AND timestamp >= ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
        bindDate(statement, index: 2, date: since)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.writeFailed
        }
    }

    func pruneRawSamples(olderThan date: Date) throws {
        let sql = "DELETE FROM raw_samples WHERE timestamp < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        bindDate(statement, index: 1, date: date)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.writeFailed
        }
    }

    func fetchRawSamples(kind: VitalSample.Kind) throws -> [RawVitalSampleRecord] {
        let sql = """
        SELECT id, timestamp, value, kind, source
        FROM raw_samples
        WHERE kind = ?
        ORDER BY timestamp DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, SQLITE_TRANSIENT)

        var items: [RawVitalSampleRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let timestamp = dateFromUnix(sqlite3_column_double(statement, 1))
            let value = sqlite3_column_double(statement, 2)
            let kindText = stringValue(statement, index: 3)
            let parsedKind: VitalSample.Kind
            switch kindText {
            case "heart_rate":
                parsedKind = .heartRate
            case "respiratory_rate":
                parsedKind = .respiratoryRate
            case "hrv_sdnn":
                parsedKind = .hrv
            case "sleep":
                parsedKind = .sleep
            case "standing":
                parsedKind = .standing
            case "walking":
                parsedKind = .walking
            case "running":
                parsedKind = .running
            case "sedentary":
                parsedKind = .sedentary
            default:
                continue
            }
            let source = stringValue(statement, index: 4)
            items.append(RawVitalSampleRecord(id: id, timestamp: timestamp, value: value, kind: parsedKind, source: source))
        }
        return items
    }

    func latestRawSampleTimestamp(kind: VitalSample.Kind) throws -> Date? {
        let sql = """
        SELECT MAX(timestamp)
        FROM raw_samples
        WHERE kind = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL {
            return nil
        }
        return dateFromUnix(sqlite3_column_double(statement, 0))
    }

    private func createTablesIfNeeded() throws {
        let createMinute = """
        CREATE TABLE IF NOT EXISTS vitals_minute (
          timestamp_minute REAL PRIMARY KEY,
          heart_rate_avg REAL,
          heart_rate_min REAL,
          heart_rate_max REAL,
          resp_rate_avg REAL,
          sample_count INTEGER NOT NULL,
          source TEXT NOT NULL,
          quality_flag TEXT NOT NULL
        );
        """
        let createRaw = """
        CREATE TABLE IF NOT EXISTS raw_samples (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp REAL NOT NULL,
          value REAL NOT NULL,
          kind TEXT NOT NULL,
          source TEXT NOT NULL
        );
        """
        try execute(createMinute)
        try execute(createRaw)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
    }

    private func beginTransaction() throws { try execute("BEGIN TRANSACTION;") }
    private func commitTransaction() throws { try execute("COMMIT;") }
    private func rollbackTransaction() throws { try execute("ROLLBACK;") }

    private func bindDate(_ statement: OpaquePointer?, index: Int32, date: Date) {
        sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
    }

    private func bindNullableDouble(_ statement: OpaquePointer?, index: Int32, value: Double?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func valueOrNil(_ statement: OpaquePointer?, index: Int32) -> Double? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    private func stringValue(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func dateFromUnix(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value)
    }
}

private enum DatabaseError: Error {
    case openFailed
    case queryFailed
    case writeFailed
}
