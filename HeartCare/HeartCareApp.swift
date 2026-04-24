//
//  HeartCareApp.swift
//  HeartCare
//
//  Created by max noah on 4/21/R8.
//

import SwiftUI
import BackgroundTasks
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let store = VitalStore()
            await store.sync()
            if store.lastError == nil {
                completionHandler(.newData)
            } else {
                completionHandler(.failed)
            }
        }
    }
}

@main
struct HeartCareApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private static let refreshTaskIdentifier = "HeartCare.refresh"
    private static var canUseBackgroundRefreshTask: Bool {
        guard let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] else {
            return false
        }
        return identifiers.contains(refreshTaskIdentifier)
    }

    init() {
        guard Self.canUseBackgroundRefreshTask else { return }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleAppRefresh(task: refreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    Self.scheduleAppRefresh()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        Self.scheduleAppRefresh()
                    }
                }
        }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()

        let syncTask = Task { @MainActor in
            let store = VitalStore()
            await store.sync()
            return store.lastError == nil
        }

        task.expirationHandler = {
            syncTask.cancel()
        }

        Task {
            let success = await syncTask.value
            task.setTaskCompleted(success: success)
        }
    }

    private static func scheduleAppRefresh() {
        guard canUseBackgroundRefreshTask else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        // 系统会自行调度，最早 15 分钟后尝试唤醒。
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 忽略重复提交等可恢复错误，避免打断主流程。
        }
    }
}
