import Combine
import Foundation

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
        isSyncing = true
        defer { isSyncing = false }
        guard let database else { return }

        let isInitialBackfillDone = UserDefaults.standard.bool(forKey: initialNinetyDayBackfillDoneKey)
        let windowDays = isInitialBackfillDone ? 1 : 90
        let windowSince = calendar.date(byAdding: .day, value: -windowDays, to: Date())
            ?? Date().addingTimeInterval(Double(-windowDays * 24 * 3600))
        await runIndependentSyncPipelines(
            database: database,
            healthWindowSince: windowSince,
            motionWindowSince: windowSince,
            shouldPruneOldData: false
        )
        if !isInitialBackfillDone {
            UserDefaults.standard.set(true, forKey: initialNinetyDayBackfillDoneKey)
        }
    }

    func syncRecent7Days() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        guard let database else { return }

        let manualWindowSince = calendar.date(byAdding: .day, value: -7, to: Date())
            ?? Date().addingTimeInterval(-7 * 24 * 3600)
        await runIndependentSyncPipelines(
            database: database,
            healthWindowSince: manualWindowSince,
            motionWindowSince: manualWindowSince,
            shouldPruneOldData: false
        )
    }

    private func runIndependentSyncPipelines(
        database: VitalDatabase,
        healthWindowSince: Date,
        motionWindowSince: Date,
        shouldPruneOldData: Bool
    ) async {
        var pipelineErrors: [String] = []

        do {
            try await syncHealthPipeline(database: database, windowSince: healthWindowSince)
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
        saveLastSyncDate(Date())
        saveLastActivitySyncDate(Date())
        lastError = pipelineErrors.isEmpty ? nil : pipelineErrors.joined(separator: " | ")
    }

    private func syncHealthPipeline(database: VitalDatabase, windowSince: Date) async throws {
        let fetchedHealth = try await healthKitService.fetchSamples(since: windowSince)
        let fetchedSleepIntervals = try await healthKitService.fetchSleepIntervals(since: windowSince)
        let healthKinds: Set<VitalSample.Kind> = [.heartRate, .respiratoryRate, .hrv]
        var newHealthSamples: [VitalSample] = []
        for kind in healthKinds {
            let latestTimestamp = try database.latestRawSampleTimestamp(kind: kind)
            let fresh = fetchedHealth.filter { sample in
                sample.kind == kind && sample.timestamp > (latestTimestamp ?? .distantPast)
            }
            newHealthSamples.append(contentsOf: fresh)
        }
        let backfillSleep = try await healthKitService.fetchActivitySamples(since: windowSince)
            .filter { $0.kind == .sleep }
        let aggregates = VitalAggregation.aggregate(samples: newHealthSamples, calendar: calendar)

        try database.insertRawSamples(newHealthSamples)
        try database.insertRawSamplesDeduplicated(backfillSleep)
        try database.upsertMinuteRecords(aggregates)
        sleepIntervalSamples = mergedSleepIntervals(existing: sleepIntervalSamples, fresh: fetchedSleepIntervals)
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
        try database.insertRawSamples(newMotionSamples)
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

    private func lastSyncDate() -> Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    private func saveLastSyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastSyncKey)
    }

    private func lastActivitySyncDate() -> Date? {
        UserDefaults.standard.object(forKey: lastActivitySyncKey) as? Date
    }

    private func saveLastActivitySyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastActivitySyncKey)
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
