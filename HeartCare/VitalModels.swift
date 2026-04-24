import Foundation

struct VitalMinuteRecord: Codable, Hashable, Identifiable {
    var id: Date { timestampMinute }
    var timestampMinute: Date
    var heartRateAvg: Double?
    var heartRateMin: Double?
    var heartRateMax: Double?
    var respiratoryRateAvg: Double?
    var sampleCount: Int
    var source: String
    var qualityFlag: String

    init(
        timestampMinute: Date,
        heartRateAvg: Double?,
        heartRateMin: Double?,
        heartRateMax: Double?,
        respiratoryRateAvg: Double?,
        sampleCount: Int,
        source: String,
        qualityFlag: String
    ) {
        self.timestampMinute = timestampMinute
        self.heartRateAvg = heartRateAvg
        self.heartRateMin = heartRateMin
        self.heartRateMax = heartRateMax
        self.respiratoryRateAvg = respiratoryRateAvg
        self.sampleCount = sampleCount
        self.source = source
        self.qualityFlag = qualityFlag
    }
}

struct VitalSample: Sendable {
    enum Kind: Sendable {
        case heartRate
        case respiratoryRate
        case hrv
        case sleep
        case standing
        case walking
        case running
        case sedentary
    }

    let timestamp: Date
    let value: Double
    let kind: Kind
    let source: String
}

extension VitalSample.Kind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "heart_rate":
            self = .heartRate
        case "respiratory_rate":
            self = .respiratoryRate
        case "hrv_sdnn":
            self = .hrv
        case "sleep":
            self = .sleep
        case "standing":
            self = .standing
        case "walking":
            self = .walking
        case "running":
            self = .running
        case "sedentary":
            self = .sedentary
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown sample kind: \(raw)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .heartRate:
            return "heart_rate"
        case .respiratoryRate:
            return "respiratory_rate"
        case .hrv:
            return "hrv_sdnn"
        case .sleep:
            return "sleep"
        case .standing:
            return "standing"
        case .walking:
            return "walking"
        case .running:
            return "running"
        case .sedentary:
            return "sedentary"
        }
    }
}

struct RawVitalSampleRecord: Codable, Hashable, Identifiable {
    let id: Int64
    let timestamp: Date
    let value: Double
    let kind: VitalSample.Kind
    let source: String
}

struct SleepIntervalSample: Sendable, Hashable, Identifiable {
    var id: String {
        "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)-\(value)-\(source)"
    }
    let start: Date
    let end: Date
    let value: Double
    let source: String
}

struct MinuteAggregate: Sendable {
    let timestampMinute: Date
    let heartRateAvg: Double?
    let heartRateMin: Double?
    let heartRateMax: Double?
    let respiratoryRateAvg: Double?
    let sampleCount: Int
    let source: String
    let qualityFlag: String
}
