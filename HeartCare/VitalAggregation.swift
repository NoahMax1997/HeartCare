import Foundation

enum VitalAggregation {
    static func aggregate(samples: [VitalSample], calendar: Calendar = .current) -> [MinuteAggregate] {
        let grouped = Dictionary(grouping: samples) {
            calendar.dateInterval(of: .minute, for: $0.timestamp)?.start ?? $0.timestamp
        }

        return grouped.keys.sorted().compactMap { minute in
            guard let bucket = grouped[minute], !bucket.isEmpty else {
                return nil
            }

            let hrValues = bucket.filter { $0.kind == .heartRate }.map(\.value)
            let rrValues = bucket.filter { $0.kind == .respiratoryRate }.map(\.value)
            let source = bucket.last?.source ?? "unknown"

            let hrAvg = hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count)
            let rrAvg = rrValues.isEmpty ? nil : rrValues.reduce(0, +) / Double(rrValues.count)
            let qualityFlag = qualityFlagForBucket(hrCount: hrValues.count, rrCount: rrValues.count)

            return MinuteAggregate(
                timestampMinute: minute,
                heartRateAvg: hrAvg,
                heartRateMin: hrValues.min(),
                heartRateMax: hrValues.max(),
                respiratoryRateAvg: rrAvg,
                sampleCount: bucket.count,
                source: source,
                qualityFlag: qualityFlag
            )
        }
    }

    private static func qualityFlagForBucket(hrCount: Int, rrCount: Int) -> String {
        if hrCount == 0 && rrCount == 0 {
            return "missing"
        }
        if hrCount > 0 && rrCount > 0 {
            return "complete"
        }
        return "partial"
    }
}
