import Foundation
import HealthKit

final class HealthKitService {
    private let store = HKHealthStore()

    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)
    private let respiratoryType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate)
    private let restingHeartRateType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)
    private let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    private let sleepAnalysisType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let heartRateType,
              let respiratoryType,
              let restingHeartRateType,
              let hrvType,
              let sleepAnalysisType else {
            throw HealthKitError.unavailable
        }

        try await store.requestAuthorization(toShare: [], read: [heartRateType, respiratoryType, restingHeartRateType, hrvType, sleepAnalysisType])
    }

    func fetchSamples(since: Date?) async throws -> [VitalSample] {
        guard let heartRateType, let respiratoryType, let hrvType else {
            throw HealthKitError.unavailable
        }

        async let hr = fetchQuantitySamples(type: heartRateType, since: since, kind: .heartRate)
        async let rr = fetchQuantitySamples(type: respiratoryType, since: since, kind: .respiratoryRate)
        async let hrv = fetchQuantitySamples(type: hrvType, since: since, kind: .hrv)
        async let states = fetchActivityStateSamples(since: since)

        return try await hr + rr + hrv + states
    }

    /// 指定起始时间起的全部 HRV(SDNN) 样本（HealthKit 里存多少条就拉多少条，不设 limit）。
    func fetchHRVSamples(since start: Date) async throws -> [VitalSample] {
        guard let hrvType else {
            throw HealthKitError.unavailable
        }
        return try await fetchQuantitySamples(type: hrvType, since: start, kind: .hrv)
    }

    /// 指定起始时间起的活动状态样本（仅睡眠）。
    func fetchActivitySamples(since start: Date) async throws -> [VitalSample] {
        try await fetchActivityStateSamples(since: start)
    }

    func fetchSleepIntervals(since start: Date) async throws -> [SleepIntervalSample] {
        let samples = try await fetchSleepCategorySamples(since: start)
        return samples.map { sample in
            SleepIntervalSample(
                start: sample.startDate,
                end: sample.endDate,
                value: mappedSleepStageValue(from: sample.value),
                source: sample.sourceRevision.source.name
            )
        }
    }

    func fetchSleepIntervals(in interval: DateInterval) async throws -> [SleepIntervalSample] {
        let samples = try await fetchSleepCategorySamples(in: interval)
        return samples.map { sample in
            SleepIntervalSample(
                start: sample.startDate,
                end: sample.endDate,
                value: mappedSleepStageValue(from: sample.value),
                source: sample.sourceRevision.source.name
            )
        }
    }

    private func fetchQuantitySamples(
        type: HKQuantityType,
        since: Date?,
        kind: VitalSample.Kind
    ) async throws -> [VitalSample] {
        let predicate: NSPredicate?
        if let since {
            predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        } else {
            let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date())
            predicate = HKQuery.predicateForSamples(withStart: twoWeeksAgo, end: nil, options: .strictStartDate)
        }

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .forward)]
        )

        let samples = try await descriptor.result(for: store)
        return samples.compactMap { sample in
            let unit: HKUnit
            switch kind {
            case .heartRate, .respiratoryRate:
                unit = .count().unitDivided(by: .minute())
            case .hrv:
                unit = .secondUnit(with: .milli)
            case .sleep, .standing, .walking, .running, .sedentary:
                unit = .count()
            }
            let source = sample.sourceRevision.source.name
            return VitalSample(
                timestamp: sample.endDate,
                value: sample.quantity.doubleValue(for: unit),
                kind: kind,
                source: source
            )
        }
    }

    func fetchLatestRestingHeartRate() async throws -> Double? {
        guard let restingHeartRateType else {
            throw HealthKitError.unavailable
        }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: restingHeartRateType, predicate: nil)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: store)
        guard let first = samples.first else { return nil }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return first.quantity.doubleValue(for: unit)
    }

    func fetchRestingHeartRate(on day: Date, calendar: Calendar = .current) async throws -> Double? {
        guard let restingHeartRateType else {
            throw HealthKitError.unavailable
        }
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: restingHeartRateType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: store)
        guard let first = samples.first else { return nil }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return first.quantity.doubleValue(for: unit)
    }

    func fetchLatestHRV() async throws -> Double? {
        guard let hrvType else {
            throw HealthKitError.unavailable
        }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: hrvType, predicate: nil)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: store)
        guard let first = samples.first else { return nil }
        return first.quantity.doubleValue(for: .secondUnit(with: .milli))
    }

    func fetchHRV(on day: Date, calendar: Calendar = .current) async throws -> Double? {
        guard let hrvType else {
            throw HealthKitError.unavailable
        }
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: hrvType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: store)
        guard let first = samples.first else { return nil }
        return first.quantity.doubleValue(for: .secondUnit(with: .milli))
    }

    private func fetchActivityStateSamples(since: Date?) async throws -> [VitalSample] {
        try await fetchSleepSamples(since: since)
    }

    private func fetchSleepSamples(since: Date?) async throws -> [VitalSample] {
        let samples = try await fetchSleepCategorySamples(since: since)
        return samples.compactMap { sample in
            return VitalSample(
                timestamp: sample.endDate,
                value: mappedSleepStageValue(from: sample.value),
                kind: .sleep,
                source: sample.sourceRevision.source.name
            )
        }
    }

    private func fetchSleepCategorySamples(since: Date?) async throws -> [HKCategorySample] {
        guard let sleepAnalysisType else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepAnalysisType, predicate: samplePredicate(since: since))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .forward)]
        )
        return try await descriptor.result(for: store)
    }

    private func fetchSleepCategorySamples(in interval: DateInterval) async throws -> [HKCategorySample] {
        guard let sleepAnalysisType else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepAnalysisType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .forward)]
        )
        return try await descriptor.result(for: store)
    }

    private func mappedSleepStageValue(from healthKitValue: Int) -> Double {
        if healthKitValue == HKCategoryValueSleepAnalysis.awake.rawValue {
            return 9
        }
        if healthKitValue == HKCategoryValueSleepAnalysis.asleepDeep.rawValue {
            return 4
        }
        if healthKitValue == HKCategoryValueSleepAnalysis.asleepREM.rawValue {
            return 3
        }
        if healthKitValue == HKCategoryValueSleepAnalysis.asleepCore.rawValue {
            return 2
        }
        // 未分期睡眠(asleep 或其它未知值)单独落库，后续展示层不参与处理。
        return 1
    }

    private func samplePredicate(since: Date?) -> NSPredicate? {
        if let since {
            return HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictEndDate)
        }
        let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date())
        return HKQuery.predicateForSamples(withStart: twoWeeksAgo, end: nil, options: .strictEndDate)
    }
}

enum HealthKitError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is not available on this device."
        }
    }
}
