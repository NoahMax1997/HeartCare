import Foundation

struct VitalBaselineResult {
    let hrBaseline7Day: Double?
    let rrBaseline7Day: Double?
    let hrBaseline30Day: Double?
    let rrBaseline30Day: Double?
}

struct VitalDeviationResult {
    let hasAlert: Bool
    let alertMessage: String?
}

enum VitalAnalytics {
    static func baseline(records: [VitalMinuteRecord], now: Date = .now) -> VitalBaselineResult {
        let sevenDays = records.filter { $0.timestampMinute >= now.addingTimeInterval(-7 * 24 * 3600) }
        let thirtyDays = records.filter { $0.timestampMinute >= now.addingTimeInterval(-30 * 24 * 3600) }

        return VitalBaselineResult(
            hrBaseline7Day: median(sevenDays.compactMap(\.heartRateAvg)),
            rrBaseline7Day: median(sevenDays.compactMap(\.respiratoryRateAvg)),
            hrBaseline30Day: median(thirtyDays.compactMap(\.heartRateAvg)),
            rrBaseline30Day: median(thirtyDays.compactMap(\.respiratoryRateAvg))
        )
    }

    static func detectDeviation(records: [VitalMinuteRecord], baseline: VitalBaselineResult, threshold: Double = 0.2, windowSize: Int = 5) -> VitalDeviationResult {
        let recent = records.sorted { $0.timestampMinute < $1.timestampMinute }.suffix(windowSize)
        guard recent.count == windowSize else {
            return VitalDeviationResult(hasAlert: false, alertMessage: nil)
        }

        let hrBaseline = baseline.hrBaseline7Day
        let rrBaseline = baseline.rrBaseline7Day
        let hrDeviates = deviationPasses(values: recent.compactMap(\.heartRateAvg), baseline: hrBaseline, threshold: threshold)
        let rrDeviates = deviationPasses(values: recent.compactMap(\.respiratoryRateAvg), baseline: rrBaseline, threshold: threshold)

        if hrDeviates || rrDeviates {
            return VitalDeviationResult(hasAlert: true, alertMessage: "连续\(windowSize)分钟偏离个人基线，请关注当前状态。")
        }
        return VitalDeviationResult(hasAlert: false, alertMessage: nil)
    }

    private static func deviationPasses(values: [Double], baseline: Double?, threshold: Double) -> Bool {
        guard let baseline, baseline > 0, values.count > 0 else { return false }
        return values.allSatisfy { abs($0 - baseline) / baseline >= threshold }
    }

    private static func median(_ numbers: [Double]) -> Double? {
        guard !numbers.isEmpty else { return nil }
        let sorted = numbers.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
