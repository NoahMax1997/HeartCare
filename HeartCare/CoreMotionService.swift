import CoreMotion
import Foundation

final class CoreMotionService {
    private let activityManager = CMMotionActivityManager()
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "coremotion.activity.query"
        return queue
    }()

    func fetchActivitySamples(since: Date?) async throws -> [VitalSample] {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return []
        }

        let startDate = since ?? Date(timeIntervalSince1970: 0)
        let endDate = Date()
        let activities = try await queryActivities(from: startDate, to: endDate)
        return activities.compactMap { activity in
            guard let kind = mapKind(from: activity) else { return nil }
            return VitalSample(
                timestamp: activity.startDate,
                value: 1,
                kind: kind,
                source: "CoreMotion"
            )
        }
    }

    private func queryActivities(from startDate: Date, to endDate: Date) async throws -> [CMMotionActivity] {
        try await withCheckedThrowingContinuation { continuation in
            activityManager.queryActivityStarting(from: startDate, to: endDate, to: operationQueue) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: activities ?? [])
            }
        }
    }

    private func mapKind(from activity: CMMotionActivity) -> VitalSample.Kind? {
        if activity.running {
            return .running
        }
        if activity.walking {
            return .walking
        }
        if activity.stationary {
            return .sedentary
        }
        return nil
    }
}
