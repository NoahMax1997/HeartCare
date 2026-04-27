import Combine
import Foundation

struct SyncDelta {
    var heartRateAdded: Int = 0
    var respiratoryAdded: Int = 0
    var hrvAdded: Int = 0
    var sleepIntervalsAdded: Int = 0

    static let zero = SyncDelta()
}

@MainActor
final class VitalStore: ObservableObject {
    @Published private(set) var records: [VitalMinuteRecord] = []
    @Published private(set) var heartRateSamples: [RawVitalSampleRecord] = []
    @Published private(set) var respiratorySamples: [RawVitalSampleRecord] = []
    @Published private(set) var hrvSamples: [RawVitalSampleRecord] = []
    @Published private(set) var sleepSamples: [RawVitalSampleRecord] = []
    @Published private(set) var sleepIntervalSamples: [SleepIntervalSample] = []
    @Published private(set) var walkingSamples: [RawVitalSampleRecord] = []
    @Published private(set) var runningSamples: [RawVitalSampleRecord] = []
    @Published private(set) var sedentarySamples: [RawVitalSampleRecord] = []
    @Published private(set) var restingHeartRate: Double?
    @Published private(set) var hrvSdnn: Double?
    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var authorizationStatus: String = "未授权"
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastSyncDelta: SyncDelta = .zero

    private let healthKitService = HealthKitService()
    private let coreMotionService = CoreMotionService()
    private let calendar = Calendar.current
    private let lastSyncKey = "vital.lastSyncDate"
    private let lastActivitySyncKey = "vital.lastActivitySyncDate"
    private let initialNinetyDayBackfillDoneKey = "vital.initialNinetyDayBackfillDone_v1"
    private let legacyMigrationDoneKey = "vital.legacyJsonMigrated"
    private let rawRetentionDays = 30
    private let autoSyncIntervalNanoseconds: UInt64 = 10 * 60 * 1_000_000_000
    private let database: VitalDatabase?
    private var autoSyncTask: Task<Void, Never>?
    private var loadedSleepIntervalDays: Set<Date> = []
    private static let syncLockUntilKey = "vital.syncLockUntil"
    private static let syncLockTokenKey = "vital.syncLockToken"
    private static let syncLockDuration: TimeInterval = 120

    init() {
        do {
            self.database = try VitalDatabase()
        } catch {
            self.database = nil
            self.lastError = "数据库初始化失败: \(error.localizedDescription)"
        }
    }

    deinit {
        autoSyncTask?.cancel()
    }

    func refresh() {
        guard let database else { return }
        do {
            try migrateLegacyMinuteJsonIfNeeded(database: database)
            records = try database.fetchMinuteRecords()
            heartRateSamples = try database.fetchRawSamples(kind: .heartRate)
            respiratorySamples = try database.fetchRawSamples(kind: .respiratoryRate)
            hrvSamples = try database.fetchRawSamples(kind: .hrv)
            sleepSamples = try database.fetchRawSamples(kind: .sleep)
            walkingSamples = try database.fetchRawSamples(kind: .walking)
            runningSamples = try database.fetchRawSamples(kind: .running)
            sedentarySamples = try database.fetchRawSamples(kind: .sedentary)
            lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        } catch {
            lastError = "读取本地数据失败: \(error.localizedDescription)"
        }
    }

    func requestAccess() async {
        do {
            try await healthKitService.requestAuthorization()
            restingHeartRate = try await healthKitService.fetchLatestRestingHeartRate()
            hrvSdnn = try await healthKitService.fetchLatestHRV()
            authorizationStatus = "已授权"
        } catch {
            authorizationStatus = "授权失败"
            lastError = error.localizedDescription
        }
    }

    func sync() async {
        guard !isSyncing else { return }
        guard let lockToken = Self.acquireSyncLock() else { return }
        defer { Self.releaseSyncLock(token: lockToken) }
        isSyncing = true
        defer { isSyncing = false }
        guard let database else { return }

        let isInitialBackfillDone = UserDefaults.standard.bool(forKey: initialNinetyDayBackfillDoneKey)
        let hasExistingHealthData = hasAnyHealthRawSamples(database: database)
        let shouldRunInitialBackfill = !isInitialBackfillDone || !hasExistingHealthData
        let windowDays = shouldRunInitialBackfill ? 90 : 1
        let windowSince = calendar.date(byAdding: .day, value: -windowDays, to: Date())
            ?? Date().addingTimeInterval(Double(-windowDays * 24 * 3600))
        let healthSyncSucceeded = await runIndependentSyncPipelines(
            database: database,
            healthWindowSince: windowSince,
            motionWindowSince: windowSince,
            shouldPruneOldData: false
        )
        if shouldRunInitialBackfill && healthSyncSucceeded {
            UserDefaults.standard.set(true, forKey: initialNinetyDayBackfillDoneKey)
        }
    }

    func syncRecent7Days() async {
        guard !isSyncing else { return }
        guard let lockToken = Self.acquireSyncLock() else { return }
        defer { Self.releaseSyncLock(token: lockToken) }
        isSyncing = true
        defer { isSyncing = false }
        guard let database else { return }

        let manualWindowSince = calendar.date(byAdding: .day, value: -7, to: Date())
            ?? Date().addingTimeInterval(-7 * 24 * 3600)
        _ = await runIndependentSyncPipelines(
            database: database,
            healthWindowSince: manualWindowSince,
            motionWindowSince: manualWindowSince,
            shouldPruneOldData: false
        )
    }

    func shouldSyncOnActive(minimumInterval: TimeInterval = 10 * 60) -> Bool {
        guard let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastSync) >= minimumInterval
    }

    private func runIndependentSyncPipelines(
        database: VitalDatabase,
        healthWindowSince: Date,
        motionWindowSince: Date,
        shouldPruneOldData: Bool
    ) async -> Bool {
        var pipelineErrors: [String] = []
        var healthSyncSucceeded = false
        var healthDelta: SyncDelta = .zero

        do {
            healthDelta = try await syncHealthPipeline(database: database, windowSince: healthWindowSince)
            healthSyncSucceeded = true
        } catch {
            pipelineErrors.append("健康数据同步失败: \(error.localizedDescription)")
        }

        do {
            try await syncMotionPipeline(database: database, windowSince: motionWindowSince)
        } catch {
            pipelineErrors.append("CoreMotion 同步失败: \(error.localizedDescription)")
        }

        if shouldPruneOldData {
            do {
                try database.pruneRawSamples(olderThan: Date().addingTimeInterval(Double(-rawRetentionDays * 24 * 3600)))
            } catch {
                pipelineErrors.append("清理旧数据失败: \(error.localizedDescription)")
            }
        }

        do {
            restingHeartRate = try await healthKitService.fetchLatestRestingHeartRate()
            hrvSdnn = try await healthKitService.fetchLatestHRV()
        } catch {
            pipelineErrors.append("刷新参考值失败: \(error.localizedDescription)")
        }

        refresh()
        if healthSyncSucceeded {
            saveLastSyncDate(Date())
            lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
            lastSyncDelta = healthDelta
        }
        saveLastActivitySyncDate(Date())
        lastError = pipelineErrors.isEmpty ? nil : pipelineErrors.joined(separator: " | ")
        return healthSyncSucceeded
    }

    private func hasAnyHealthRawSamples(database: VitalDatabase) -> Bool {
        let healthKinds: [VitalSample.Kind] = [.heartRate, .respiratoryRate, .hrv, .sleep]
        for kind in healthKinds {
            if (try? database.latestRawSampleTimestamp(kind: kind)) ?? nil != nil {
                return true
            }
        }
        return false
    }

    private func syncHealthPipeline(database: VitalDatabase, windowSince: Date) async throws -> SyncDelta {
        let fetchedHealth = try await healthKitService.fetchSamples(since: windowSince)
        let fetchedSleepIntervals = try await healthKitService.fetchSleepIntervals(since: windowSince)
        let latestHeartRateTimestamp = try database.latestRawSampleTimestamp(kind: .heartRate)
        let latestRespiratoryTimestamp = try database.latestRawSampleTimestamp(kind: .respiratoryRate)
        let latestHrvTimestamp = try database.latestRawSampleTimestamp(kind: .hrv)

        let newHeartRateSamples = fetchedHealth.filter {
            $0.kind == .heartRate && $0.timestamp > (latestHeartRateTimestamp ?? .distantPast)
        }
        let newRespiratorySamples = fetchedHealth.filter {
            $0.kind == .respiratoryRate && $0.timestamp > (latestRespiratoryTimestamp ?? .distantPast)
        }
        let newHrvSamples = fetchedHealth.filter {
            $0.kind == .hrv && $0.timestamp > (latestHrvTimestamp ?? .distantPast)
        }

        let newHealthSamples = newHeartRateSamples + newRespiratorySamples + newHrvSamples
        let backfillSleep = try await healthKitService.fetchActivitySamples(since: windowSince)
            .filter { $0.kind == .sleep }
        let aggregates = VitalAggregation.aggregate(samples: newHealthSamples, calendar: calendar)

        let heartRateAdded = try database.insertRawSamples(newHeartRateSamples)
        let respiratoryAdded = try database.insertRawSamples(newRespiratorySamples)
        let hrvAdded = try database.insertRawSamplesDeduplicatedIgnoringSource(newHrvSamples)
        let sleepAdded = try database.insertRawSamplesDeduplicated(backfillSleep)
        try database.upsertMinuteRecords(aggregates)
        sleepIntervalSamples = mergedSleepIntervals(existing: sleepIntervalSamples, fresh: fetchedSleepIntervals)
        return SyncDelta(
            heartRateAdded: heartRateAdded,
            respiratoryAdded: respiratoryAdded,
            hrvAdded: hrvAdded,
            sleepIntervalsAdded: sleepAdded
        )
    }

    private func syncMotionPipeline(database: VitalDatabase, windowSince: Date) async throws {
        let fetchedMotion = try await coreMotionService.fetchActivitySamples(since: windowSince)
        let motionKinds: Set<VitalSample.Kind> = [.walking, .running, .sedentary]
        var newMotionSamples: [VitalSample] = []
        for kind in motionKinds {
            let latestTimestamp = try database.latestRawSampleTimestamp(kind: kind)
            let fresh = fetchedMotion.filter { sample in
                sample.kind == kind && sample.timestamp > (latestTimestamp ?? .distantPast)
            }
            newMotionSamples.append(contentsOf: fresh)
        }
        _ = try database.insertRawSamples(newMotionSamples)
    }

    func startAutoSyncLoop() {
        guard autoSyncTask == nil || autoSyncTask?.isCancelled == true else { return }
        autoSyncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.autoSyncIntervalNanoseconds)
                guard !Task.isCancelled else { break }
                await self.sync()
            }
        }
    }

    func stopAutoSyncLoop() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    func records(inLast days: Int, now: Date = .now) -> [VitalMinuteRecord] {
        let start = now.addingTimeInterval(Double(-days * 24 * 3600))
        return records.filter { $0.timestampMinute >= start }.sorted { $0.timestampMinute < $1.timestampMinute }
    }

    func fetchRestingHeartRateReference(for day: Date) async -> Double? {
        do {
            if calendar.isDateInToday(day) {
                let latest = try await healthKitService.fetchLatestRestingHeartRate()
                if let latest {
                    restingHeartRate = latest
                }
                return latest
            }
            return try await healthKitService.fetchRestingHeartRate(on: day, calendar: calendar)
        } catch {
            lastError = "读取静息心率失败: \(error.localizedDescription)"
            return restingHeartRate
        }
    }

    func fetchHRVReference(for day: Date) async -> Double? {
        do {
            if calendar.isDateInToday(day) {
                let latest = try await healthKitService.fetchLatestHRV()
                if let latest {
                    hrvSdnn = latest
                }
                return latest
            }
            let byDay = try await healthKitService.fetchHRV(on: day, calendar: calendar)
            if calendar.isDateInToday(day), let byDay {
                hrvSdnn = byDay
            }
            return byDay
        } catch {
            lastError = "读取 HRV 失败: \(error.localizedDescription)"
            return hrvSdnn
        }
    }

    func ensureSleepIntervalsLoaded(for day: Date) async {
        let dayStart = calendar.startOfDay(for: day)
        if loadedSleepIntervalDays.contains(dayStart) {
            return
        }
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return
        }
        let queryStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let queryEnd = calendar.date(byAdding: .day, value: 1, to: dayEnd) ?? dayEnd
        let queryRange = DateInterval(start: queryStart, end: queryEnd)

        do {
            let fetched = try await healthKitService.fetchSleepIntervals(in: queryRange)
            sleepIntervalSamples = mergedSleepIntervals(existing: sleepIntervalSamples, fresh: fetched)
            if !fetched.isEmpty {
                loadedSleepIntervalDays.insert(dayStart)
            }
        } catch {
            lastError = "按日期补拉睡眠数据失败: \(error.localizedDescription)"
        }
    }

    private func saveLastSyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastSyncKey)
    }

    private func saveLastActivitySyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastActivitySyncKey)
    }

    private static func acquireSyncLock(now: Date = Date()) -> String? {
        let defaults = UserDefaults.standard
        let lockUntil = defaults.object(forKey: syncLockUntilKey) as? Date
        if let lockUntil, lockUntil > now {
            return nil
        }
        let token = UUID().uuidString
        defaults.set(now.addingTimeInterval(syncLockDuration), forKey: syncLockUntilKey)
        defaults.set(token, forKey: syncLockTokenKey)
        return token
    }

    private static func releaseSyncLock(token: String) {
        let defaults = UserDefaults.standard
        let currentToken = defaults.string(forKey: syncLockTokenKey)
        guard currentToken == token else { return }
        defaults.removeObject(forKey: syncLockUntilKey)
        defaults.removeObject(forKey: syncLockTokenKey)
    }

    private func mergedSleepIntervals(
        existing: [SleepIntervalSample],
        fresh: [SleepIntervalSample]
    ) -> [SleepIntervalSample] {
        if fresh.isEmpty { return existing.sorted { $0.start < $1.start } }
        let merged = Set(existing).union(fresh)
        return merged.sorted { $0.start < $1.start }
    }

    private func migrateLegacyMinuteJsonIfNeeded(database: VitalDatabase) throws {
        if UserDefaults.standard.bool(forKey: legacyMigrationDoneKey) {
            return
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let legacyURL = documents.appendingPathComponent("vital_minutes.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            UserDefaults.standard.set(true, forKey: legacyMigrationDoneKey)
            return
        }

        let data = try Data(contentsOf: legacyURL)
        let legacyRecords = try JSONDecoder().decode([VitalMinuteRecord].self, from: data)
        let aggregates = legacyRecords.map {
            MinuteAggregate(
                timestampMinute: $0.timestampMinute,
                heartRateAvg: $0.heartRateAvg,
                heartRateMin: $0.heartRateMin,
                heartRateMax: $0.heartRateMax,
                respiratoryRateAvg: $0.respiratoryRateAvg,
                sampleCount: $0.sampleCount,
                source: $0.source,
                qualityFlag: $0.qualityFlag
            )
        }
        try database.upsertMinuteRecords(aggregates)
        UserDefaults.standard.set(true, forKey: legacyMigrationDoneKey)
    }
}
