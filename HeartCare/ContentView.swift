//
//  ContentView.swift
//  HeartCare
//
//  Created by max noah on 4/21/R8.
//

import SwiftUI
import Charts
import UniformTypeIdentifiers

enum TrendRange: CaseIterable {
    case day
    case week
    case month

    var title: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}

struct ContentView: View {
    @StateObject private var store = VitalStore()
    @State private var selectedRange: TrendRange = .week
    @State private var exportText = ""
    @State private var showExporter = false

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView(store: store, selectedRange: $selectedRange)
            }
            .tabItem {
                Label("趋势", systemImage: "waveform.path.ecg")
            }

            NavigationStack {
                HistoryView(store: store, exportText: $exportText, showExporter: $showExporter)
            }
            .tabItem {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }

            NavigationStack {
                SettingsView(store: store)
            }
            .tabItem {
                Label("设置", systemImage: "gear")
            }
        }
        .task {
            await store.requestAccess()
            store.refresh()
            await store.sync()
            store.startAutoSyncLoop()
        }
        .onDisappear {
            store.stopAutoSyncLoop()
        }
    }
}

private struct DashboardView: View {
    @ObservedObject var store: VitalStore
    @Binding var selectedRange: TrendRange
    @State private var selectedKind: VitalSample.Kind = .heartRate
    @State private var selectedDate: Date = .now
    @State private var restingReferenceForDay: Double?
    @State private var selectedHRVPoint: DashboardPoint?
    @State private var selectedRespiratoryPoint: DashboardPoint?
    @State private var didTapPlotArea = false
    @State private var visiblePointCount: Int = .max
    @State private var hasPlayedInitialAnimation = false
    @State private var animationTask: Task<Void, Never>?
    @State private var showsSleepBackground = true
    @State private var showsWalkingBackground = true
    @State private var showsRunningBackground = true
    @State private var showsSedentaryBackground = false
    @State private var showsDeepSleepStage = true
    @State private var showsRemSleepStage = true
    @State private var showsCoreSleepStage = true
    @State private var showsAwakeSleepStage = true

    var body: some View {
        let points = samplesForSelectedDay()
        let animatedPoints = visiblePoints(from: points)
        let stats = statistics(for: points)
        let extrema = extremaPoints(for: points)
        let displayPoints = selectedKind == .heartRate ? animatedPoints : points
        let accentColor: Color = selectedKind == .heartRate ? .red : .blue
        let humanLimits = humanLimitsRange()
        let referenceValue = selectedKind == .heartRate ? (restingReferenceForDay ?? store.restingHeartRate ?? stats?.avg) : stats?.avg
        let yDomain = chartYDomain(for: displayPoints)
        let xDomain = chartXDomain(for: selectedDate, points: points)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        metricSegmentButton(
                            title: "心率",
                            systemImage: "heart.fill",
                            kind: .heartRate
                        )
                        metricSegmentButton(
                            title: "HRV",
                            systemImage: "waveform.path.ecg",
                            kind: .hrv
                        )
                        metricSegmentButton(
                            title: "呼吸",
                            systemImage: "lungs.fill",
                            kind: .respiratoryRate
                        )
                    }
                    .padding(4)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                }
                .padding(.horizontal)
                .contentShape(Rectangle())
                .onTapGesture {
                    clearTrendSelection()
                }

                chartCard(
                    points: displayPoints,
                    rawCount: points.count,
                    latestPoint: points.last,
                    stats: stats,
                    extrema: extrema,
                    color: accentColor,
                    humanLimits: humanLimits,
                    referenceValue: referenceValue,
                    yDomain: yDomain,
                    xDomain: xDomain
                )
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("HeartCare")
        .onAppear {
            selectedDate = Date()
            if selectedKind == .heartRate && !hasPlayedInitialAnimation {
                hasPlayedInitialAnimation = true
                replayLineAnimation(totalPoints: points.count)
            }
        }
        .task(id: selectedDate) {
            if selectedKind == .heartRate {
                restingReferenceForDay = await store.fetchRestingHeartRateReference(for: selectedDate)
                replayLineAnimation(totalPoints: points.count)
            }
        }
        .onChange(of: selectedKind) { _, newKind in
            if newKind == .heartRate {
                Task {
                    restingReferenceForDay = await store.fetchRestingHeartRateReference(for: selectedDate)
                }
            } else {
                restingReferenceForDay = nil
                animationTask?.cancel()
                animationTask = nil
            }
            if newKind != .hrv {
                selectedHRVPoint = nil
            }
            if newKind != .respiratoryRate {
                selectedRespiratoryPoint = nil
            }
        }
        .onChange(of: points.count) { _, newCount in
            guard selectedKind == .heartRate else { return }
            visiblePointCount = newCount
        }
        .onChange(of: points.map(\.id)) { _, pointIDs in
            guard selectedKind == .hrv, let selected = selectedHRVPoint else { return }
            if !pointIDs.contains(selected.id) {
                selectedHRVPoint = nil
            }
        }
        .onChange(of: points.map(\.id)) { _, pointIDs in
            guard selectedKind == .respiratoryRate, let selected = selectedRespiratoryPoint else { return }
            if !pointIDs.contains(selected.id) {
                selectedRespiratoryPoint = nil
            }
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private func chartCard(
        points: [DashboardPoint],
        rawCount: Int,
        latestPoint: DashboardPoint?,
        stats: ChartStats?,
        extrema: (min: DashboardPoint, max: DashboardPoint)?,
        color: Color,
        humanLimits: ClosedRange<Double>,
        referenceValue: Double?,
        yDomain: ClosedRange<Double>,
        xDomain: ClosedRange<Date>
    ) -> some View {
        let sleepIntervals = sleepSegments(for: selectedDate, xDomain: xDomain)
        let sleepStageIntervals = sleepStageSegments(for: selectedDate, xDomain: xDomain)
        let selectedRespSleepStageIntervals = selectedSleepStageSegments(from: sleepStageIntervals)
        let runningIntervals = activitySegments(for: selectedDate, xDomain: xDomain, kind: .running)
        let walkingIntervals = subtractOverlaps(
            from: activitySegments(for: selectedDate, xDomain: xDomain, kind: .walking),
            with: runningIntervals
        )
        let sedentaryIntervals = subtractOverlaps(
            from: activitySegments(for: selectedDate, xDomain: xDomain, kind: .sedentary),
            with: walkingIntervals + runningIntervals + sleepIntervals.map { ActivitySegment(start: $0.start, end: $0.end) }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.blue)
                    DatePicker("", selection: $selectedDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .scaleEffect(0.84)
                        .font(.callout.weight(.semibold))
                }
                .frame(height: 30)

                Spacer()

                if selectedKind == .heartRate || selectedKind == .hrv {
                    HStack(spacing: 8) {
                        colorHintChip(
                            iconColor: .blue.opacity(0.95),
                            chipColor: .blue.opacity(0.40),
                            icon: "bed.double.fill",
                            isSelected: showsSleepBackground
                        ) {
                            showsSleepBackground.toggle()
                        }
                        colorHintChip(
                            iconColor: .green.opacity(0.95),
                            chipColor: .green.opacity(0.34),
                            icon: "figure.walk",
                            isSelected: showsWalkingBackground
                        ) {
                            showsWalkingBackground.toggle()
                        }
                        colorHintChip(
                            iconColor: .orange.opacity(0.95),
                            chipColor: .orange.opacity(0.34),
                            icon: "figure.run",
                            isSelected: showsRunningBackground
                        ) {
                            showsRunningBackground.toggle()
                        }
                        colorHintChip(
                            iconColor: .gray.opacity(0.95),
                            chipColor: .gray.opacity(0.34),
                            icon: "figure.seated.side",
                            isSelected: showsSedentaryBackground
                        ) {
                            showsSedentaryBackground.toggle()
                        }
                    }
                } else if selectedKind == .respiratoryRate {
                    HStack(spacing: 8) {
                        sleepStageHintChip(
                            iconColor: sleepStageColor(for: .deep).opacity(0.95),
                            chipColor: sleepStageColor(for: .deep),
                            icon: "moon.stars.fill",
                            label: "深度",
                            isSelected: showsDeepSleepStage
                        ) {
                            showsDeepSleepStage.toggle()
                        }
                        sleepStageHintChip(
                            iconColor: sleepStageColor(for: .core).opacity(0.95),
                            chipColor: sleepStageColor(for: .core),
                            icon: "moon.fill",
                            label: "核心",
                            isSelected: showsCoreSleepStage
                        ) {
                            showsCoreSleepStage.toggle()
                        }
                        sleepStageHintChip(
                            iconColor: sleepStageColor(for: .rem).opacity(0.95),
                            chipColor: sleepStageColor(for: .rem),
                            icon: "sparkles",
                            label: "安宁",
                            isSelected: showsRemSleepStage
                        ) {
                            showsRemSleepStage.toggle()
                        }
                        sleepStageHintChip(
                            iconColor: sleepStageColor(for: .awake).opacity(0.95),
                            chipColor: sleepStageColor(for: .awake),
                            icon: "sun.max.fill",
                            label: "清醒",
                            isSelected: showsAwakeSleepStage
                        ) {
                            showsAwakeSleepStage.toggle()
                        }
                    }
                }

            }
            .contentShape(Rectangle())
            .onTapGesture {
                clearTrendSelection()
            }

            if points.isEmpty {
                Text("该日期暂无采集数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
            } else {
                Chart {
                    activityOverlayContent(
                        showsOverlay: (selectedKind == .heartRate || selectedKind == .hrv) && showsWalkingBackground,
                        segments: walkingIntervals,
                        yDomain: yDomain,
                        color: .green.opacity(0.34),
                        systemImage: "figure.walk"
                    )
                    activityOverlayContent(
                        showsOverlay: (selectedKind == .heartRate || selectedKind == .hrv) && showsRunningBackground,
                        segments: runningIntervals,
                        yDomain: yDomain,
                        color: .orange.opacity(0.34),
                        systemImage: "figure.run"
                    )
                    activityOverlayContent(
                        showsOverlay: (selectedKind == .heartRate || selectedKind == .hrv) && showsSedentaryBackground,
                        segments: sedentaryIntervals,
                        yDomain: yDomain,
                        color: .gray.opacity(0.28),
                        systemImage: "figure.seated.side"
                    )
                    sleepOverlayContent(
                        showsSleepOverlay: ((selectedKind == .heartRate || selectedKind == .hrv) && showsSleepBackground) || selectedKind == .respiratoryRate,
                        segments: selectedKind == .respiratoryRate ? selectedRespSleepStageIntervals : sleepIntervals,
                        yDomain: yDomain,
                        style: selectedKind == .respiratoryRate ? .byStage : .unified
                    )

                    ForEach(points, id: \.id) { item in
                        LineMark(
                            x: .value("时间", item.timestamp),
                            y: .value("数值", item.value)
                        )
                        .foregroundStyle(usesSoftTrendStyle ? Color.gray.opacity(0.35) : .red)
                        .lineStyle(.init(lineWidth: usesSoftTrendStyle ? 2 : 1))
                        .interpolationMethod(.catmullRom)
                        if usesSoftTrendStyle {
                            PointMark(
                                x: .value("时间", item.timestamp),
                                y: .value("数值", item.value)
                            )
                            .symbolSize(selectedKind == .respiratoryRate ? 24 : 36)
                            .foregroundStyle(trendPointColor(for: item.value))
                        }
                    }

                    if selectedKind == .hrv, let selected = selectedHRVPoint {
                        PointMark(
                            x: .value("时间", selected.timestamp),
                            y: .value("数值", selected.value)
                        )
                        .symbolSize(74)
                        .foregroundStyle(trendPointColor(for: selected.value))

                        PointMark(
                            x: .value("时间", selected.timestamp),
                            y: .value("数值", selected.value)
                        )
                        .symbolSize(30)
                        .foregroundStyle(.white)
                        .annotation(position: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hrvStatusText(for: selected.value))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(trendPointColor(for: selected.value))
                                HStack(spacing: 0) {
                                    Text("HRV:\(shortTimeString(selected.timestamp))~")
                                        .foregroundStyle(.secondary)
                                    Text("\(String(format: "%.1f", selected.value))ms")
                                        .foregroundStyle(trendPointColor(for: selected.value))
                                }
                                .font(.caption2)
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(Color.gray.opacity(0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    if selectedKind == .respiratoryRate, let selected = selectedRespiratoryPoint {
                        PointMark(
                            x: .value("时间", selected.timestamp),
                            y: .value("数值", selected.value)
                        )
                        .symbolSize(62)
                        .foregroundStyle(trendPointColor(for: selected.value))

                        PointMark(
                            x: .value("时间", selected.timestamp),
                            y: .value("数值", selected.value)
                        )
                        .symbolSize(22)
                        .foregroundStyle(.white)
                        .annotation(position: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(respiratoryStatusText(for: selected.value))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(trendPointColor(for: selected.value))
                                HStack(spacing: 0) {
                                    Text("呼吸:\(shortTimeString(selected.timestamp))~")
                                        .foregroundStyle(.secondary)
                                    Text("\(String(format: "%.1f", selected.value))次/分")
                                        .foregroundStyle(trendPointColor(for: selected.value))
                                }
                                .font(.caption2)
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(Color.gray.opacity(0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    if selectedKind == .heartRate, let tail = points.last {
                        PointMark(
                            x: .value("时间", tail.timestamp),
                            y: .value("数值", tail.value)
                        )
                        .symbolSize(170)
                        .foregroundStyle(Color.red.opacity(0.2))

                        PointMark(
                            x: .value("时间", tail.timestamp),
                            y: .value("数值", tail.value)
                        )
                        .symbolSize(45)
                        .foregroundStyle(.red)
                    }

                    if let stats {
                        if selectedKind == .heartRate {
                        RuleMark(y: .value("最低", stats.min))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .annotation(position: .trailing) {
                                if !isApproximatelyEqual(stats.min, humanLimits.lowerBound) &&
                                    !isApproximatelyEqual(stats.min, humanLimits.upperBound) {
                                    Text(String(format: "%.1f", stats.min))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                        if let referenceValue {
                            RuleMark(y: .value("参考", referenceValue))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .annotation(position: .trailing) {
                                if selectedKind == .heartRate {
                                    Text("静息:\(String(format: "%.1f", referenceValue))")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("平均:\(String(format: "%.1f", referenceValue))")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                }
                            }
                        }
                        RuleMark(y: .value("最高", stats.max))
                            .foregroundStyle(.purple)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .annotation(position: .trailing) {
                                if !isApproximatelyEqual(stats.max, humanLimits.lowerBound) &&
                                    !isApproximatelyEqual(stats.max, humanLimits.upperBound) {
                                    Text(String(format: "%.1f", stats.max))
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                }
                            }
                        }
                    }

                    if selectedKind == .respiratoryRate {
                        RuleMark(y: .value("呼吸低阈值", 10))
                            .foregroundStyle(Color(red: 0.55, green: 0.05, blue: 0.10))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))

                        RuleMark(y: .value("呼吸高阈值", 20))
                            .foregroundStyle(.red)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    } else if selectedKind == .hrv {
                        RuleMark(y: .value("HRV低阈值", 30))
                            .foregroundStyle(Color(red: 0.55, green: 0.05, blue: 0.10))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))

                        RuleMark(y: .value("HRV高阈值", 60))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))

                        if let stats {
                            RuleMark(y: .value("HRV平均值", stats.avg))
                                .foregroundStyle(.yellow)
                                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                                .annotation(position: .trailing) {
                                    Text(String(format: "%.1f", stats.avg))
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                        }
                    } else {
                        RuleMark(y: .value("人类下限", humanLimits.lowerBound))
                            .foregroundStyle(.gray)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .annotation(position: .trailing) {
                                Text(String(format: "%.0f", humanLimits.lowerBound))
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                            }

                        RuleMark(y: .value("人类上限", humanLimits.upperBound))
                            .foregroundStyle(.gray)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .annotation(position: .trailing) {
                                Text(String(format: "%.0f", humanLimits.upperBound))
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                            }
                    }
                }
                .frame(height: 280)
                .padding(.bottom, 18)
                .chartYScale(domain: yDomain)
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 1)) { value in
                        AxisGridLine()
                        AxisTick()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .onTapGesture {
                    if !didTapPlotArea {
                        clearTrendSelection()
                    }
                    didTapPlotArea = false
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            if let plotFrame = proxy.plotFrame {
                                let frame = geometry[plotFrame]
                                ForEach(evenHourAxisDates(in: xDomain), id: \.self) { date in
                                    if let xPosition = proxy.position(forX: date) {
                                        Text(hourAxisLabel(for: date))
                                            .font(.system(size: 10, weight: .regular, design: .rounded))
                                            .monospacedDigit()
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                            .allowsTightening(true)
                                            .position(x: frame.origin.x + xPosition, y: frame.maxY + 6)
                                    }
                                }
                            }

                            if selectedKind == .hrv || selectedKind == .respiratoryRate {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            guard let plotFrame = proxy.plotFrame else {
                                                clearTrendSelection()
                                                return
                                            }
                                            let frame = geometry[plotFrame]
                                            let xPosition = value.location.x - frame.origin.x
                                            guard xPosition >= 0, xPosition <= frame.size.width else {
                                                clearTrendSelection()
                                                return
                                            }
                                            guard let tappedDate: Date = proxy.value(atX: xPosition) else {
                                                clearTrendSelection()
                                                return
                                            }
                                            didTapPlotArea = true
                                            if selectedKind == .hrv {
                                                selectedHRVPoint = nearestPoint(to: tappedDate, in: points)
                                            } else if selectedKind == .respiratoryRate {
                                                selectedRespiratoryPoint = nearestPoint(to: tappedDate, in: points)
                                            }
                                        }
                                )
                            }
                        }
                    }
                }

                if selectedKind == .respiratoryRate {
                    Text("睡眠阶段排查：原始\(sleepStageIntervals.count)段 / 筛选后\(selectedRespSleepStageIntervals.count)段")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                if let extrema, selectedKind == .heartRate {
                    HStack(spacing: 8) {
                        Text("最低点时间：\(dateTimeString(extrema.min.timestamp))")
                            .font(.caption2)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())

                        Text("最高点时间：\(dateTimeString(extrema.max.timestamp))")
                            .font(.caption2)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .foregroundStyle(.secondary)
                }

                if let referenceValue {
                    HStack(spacing: 8) {
                        Text("\(selectedKind == .heartRate ? "高于静息占比" : "高于平均占比")：\(String(format: "%.1f", aboveReferencePercentage(points: points, reference: referenceValue)))%")
                            .font(.caption2)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)

                        if selectedKind == .heartRate || selectedKind == .respiratoryRate || selectedKind == .hrv {
                            Text("采集点 \(rawCount) 条")
                                .font(.caption2)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color.blue.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.secondary)
                        }

                        if Calendar.current.isDateInToday(selectedDate),
                           (selectedKind == .heartRate || selectedKind == .hrv),
                           let latestPoint {
                            Text("最新 \(shortTimeString(latestPoint.timestamp))～\(String(format: "%.1f", latestPoint.value))\(selectedKind == .heartRate ? " bpm" : " ms")")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color.red.opacity(0.85))
                                .clipShape(Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        clearTrendSelection()
                    }
                }

            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metricSegmentButton(title: String, systemImage: String, kind: VitalSample.Kind) -> some View {
        Button {
            selectedKind = kind
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(metricIconColor(for: kind))
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedKind == kind ? metricIconColor(for: kind).opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        selectedKind == kind ? metricIconColor(for: kind).opacity(0.35) : Color.gray.opacity(0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func colorHintChip(
        iconColor: Color,
        chipColor: Color,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(isSelected ? "开" : "关")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.7))
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? iconColor.opacity(1.0) : iconColor.opacity(0.45))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(
                Capsule()
                    .fill(chipColor.opacity(isSelected ? 0.08 : 0.58))
            )
            .overlay(
                Capsule()
                    .stroke(iconColor.opacity(isSelected ? 0.95 : 0.3), lineWidth: isSelected ? 1.4 : 0.8)
            )
            .scaleEffect(isSelected ? 1.0 : 0.96)
        }
        .buttonStyle(.plain)
    }

    private func sleepStageHintChip(
        iconColor: Color,
        chipColor: Color,
        icon: String,
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(isSelected ? "开" : "关")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.7))
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? iconColor.opacity(1.0) : iconColor.opacity(0.45))
                Text(label)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.7))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(
                Capsule()
                    .fill(chipColor.opacity(isSelected ? 0.14 : 0.58))
            )
            .overlay(
                Capsule()
                    .stroke(iconColor.opacity(isSelected ? 0.95 : 0.3), lineWidth: isSelected ? 1.4 : 0.8)
            )
            .scaleEffect(isSelected ? 1.0 : 0.96)
        }
        .buttonStyle(.plain)
    }

    private func metricIconColor(for kind: VitalSample.Kind) -> Color {
        switch kind {
        case .heartRate:
            return .red
        case .respiratoryRate:
            return .teal
        case .hrv:
            return .mint
        case .sleep:
            return .indigo
        case .standing, .walking, .running, .sedentary:
            return .gray
        }
    }

    private func samplesForSelectedDay() -> [DashboardPoint] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let source: [RawVitalSampleRecord]
        switch selectedKind {
        case .heartRate:
            source = store.heartRateSamples
        case .respiratoryRate:
            source = store.respiratorySamples
        case .hrv:
            source = store.hrvSamples
        case .sleep, .standing, .walking, .running, .sedentary:
            source = []
        }
        return source
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            .sorted { $0.timestamp < $1.timestamp }
            .map { item in
                DashboardPoint(id: Double(item.id), timestamp: item.timestamp, value: item.value)
            }
    }

    private func statistics(for points: [DashboardPoint]) -> ChartStats? {
        let values = points.map(\.value)
        guard !values.isEmpty else { return nil }
        return ChartStats(
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            avg: values.reduce(0, +) / Double(values.count)
        )
    }

    private func aboveReferencePercentage(points: [DashboardPoint], reference: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        let count = points.filter { $0.value > reference }.count
        return (Double(count) / Double(points.count)) * 100
    }

    private func chartYDomain(for points: [DashboardPoint]) -> ClosedRange<Double> {
        let humanLimits = humanLimitsRange()

        guard !points.isEmpty else {
            return humanLimits
        }

        let values = points.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return humanLimits
        }

        let lower = min(humanLimits.lowerBound, minValue)
        let upper = max(humanLimits.upperBound, maxValue)

        if lower >= upper {
            return humanLimits
        }
        return lower...upper
    }

    private func humanLimitsRange() -> ClosedRange<Double> {
        switch selectedKind {
        case .heartRate:
            return 30...130
        case .respiratoryRate:
            return 5...25
        case .hrv:
            return 10...200
        case .sleep, .standing, .walking, .running, .sedentary:
            return 0...2
        }
    }

    private func isApproximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.01) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func chartXDomain(for day: Date, points: [DashboardPoint]) -> ClosedRange<Date> {
        let calendar = Calendar.current
        if let minTime = points.map(\.timestamp).min(),
           let maxTime = points.map(\.timestamp).max() {
            var start = calendar.dateInterval(of: .hour, for: minTime)?.start ?? minTime
            var end = calendar.dateInterval(of: .hour, for: maxTime)?.start ?? maxTime

            let startHour = calendar.component(.hour, from: start)
            let startOffset = startHour % 2
            if startOffset != 0 {
                start = calendar.date(byAdding: .hour, value: -startOffset, to: start) ?? start
            }

            let endHour = calendar.component(.hour, from: end)
            let endOffset = endHour % 2
            if endOffset != 0 {
                end = calendar.date(byAdding: .hour, value: 2 - endOffset, to: end) ?? end
            }
            if end <= maxTime {
                end = calendar.date(byAdding: .hour, value: 2, to: end) ?? end
            }
            if start < end {
                return start...end
            }
        }

        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .hour, value: 24, to: dayStart) ?? dayStart
        return dayStart...dayEnd
    }

    private func hourAxisLabel(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return String(hour)
    }

    private func evenHourAxisDates(in domain: ClosedRange<Date>) -> [Date] {
        let calendar = Calendar.current
        guard var current = calendar.dateInterval(of: .hour, for: domain.lowerBound)?.start else {
            return []
        }
        if current < domain.lowerBound {
            current = calendar.date(byAdding: .hour, value: 1, to: current) ?? current
        }
        while !calendar.component(.hour, from: current).isMultiple(of: 2) {
            current = calendar.date(byAdding: .hour, value: 1, to: current) ?? current
        }

        var marks: [Date] = []
        while current <= domain.upperBound {
            marks.append(current)
            current = calendar.date(byAdding: .hour, value: 2, to: current) ?? current.addingTimeInterval(7200)
        }
        return marks
    }

    private func sleepSegments(for day: Date, xDomain: ClosedRange<Date>) -> [SleepSegment] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let intervalBased = store.sleepIntervalSamples
            .filter { interval in
                if interval.start == interval.end {
                    return interval.start >= dayStart && interval.start < dayEnd
                }
                return interval.end > dayStart && interval.start < dayEnd
            }
            .compactMap { interval -> SleepSegment? in
                var start = max(interval.start, xDomain.lowerBound)
                var end = min(interval.end, xDomain.upperBound)
                if start >= end {
                    let center = max(min(interval.end, xDomain.upperBound), xDomain.lowerBound)
                    start = max(center.addingTimeInterval(-5 * 60), xDomain.lowerBound)
                    end = min(center.addingTimeInterval(5 * 60), xDomain.upperBound)
                }
                guard start < end else { return nil }
                return SleepSegment(start: start, end: end, stage: sleepStage(for: interval.value))
            }

        let sleepPoints = store.sleepSamples
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            .sorted { $0.timestamp < $1.timestamp }

        let maxGap: TimeInterval = 60 * 60
        let minimumDuration: TimeInterval = 20 * 60
        var intervals: [(start: Date, end: Date, stage: SleepStage)] = []

        if !sleepPoints.isEmpty {
            var segmentStart = sleepPoints[0].timestamp
            var lastTimestamp = sleepPoints[0].timestamp
            let segmentStage = sleepStage(for: sleepPoints[0].value)

            for point in sleepPoints.dropFirst() {
                if point.timestamp.timeIntervalSince(lastTimestamp) <= maxGap {
                    lastTimestamp = point.timestamp
                } else {
                    intervals.append((segmentStart, lastTimestamp, segmentStage))
                    segmentStart = point.timestamp
                    lastTimestamp = point.timestamp
                }
            }
            intervals.append((segmentStart, lastTimestamp, segmentStage))
        }

        let pointBased: [SleepSegment] = intervals.compactMap { interval -> SleepSegment? in
            var start = interval.start
            var end = interval.end
            if end <= start {
                start = start.addingTimeInterval(-5 * 60)
                end = end.addingTimeInterval(5 * 60)
            } else if end.timeIntervalSince(start) < minimumDuration {
                let halfDuration = minimumDuration / 2
                start = start.addingTimeInterval(-halfDuration)
                end = end.addingTimeInterval(halfDuration)
            }
            start = max(start, xDomain.lowerBound)
            end = min(end, xDomain.upperBound)
            guard start < end else { return nil }
            return SleepSegment(start: start, end: end, stage: interval.stage)
        }

        let combined = intervalBased + pointBased
        guard !combined.isEmpty else { return [] }
        return mergeUnifiedSleepSegments(combined, within: 60 * 60)
    }

    private func sleepStageSegments(for day: Date, xDomain: ClosedRange<Date>) -> [SleepSegment] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let intervalBased = store.sleepIntervalSamples
            .filter { $0.end > dayStart && $0.start < dayEnd }
            .compactMap { interval -> SleepSegment? in
                let start = max(interval.start, xDomain.lowerBound)
                let end = min(interval.end, xDomain.upperBound)
                guard start < end else { return nil }
                return SleepSegment(start: start, end: end, stage: sleepStage(for: interval.value))
            }
        var seenKeys = Set<String>()
        let deduplicated = intervalBased.filter { segment in
            let key = "\(segment.start.timeIntervalSince1970)-\(segment.end.timeIntervalSince1970)-\(segment.stage)"
            return seenKeys.insert(key).inserted
        }
        return deduplicated.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return sleepStageRenderRank(lhs.stage) < sleepStageRenderRank(rhs.stage)
            }
            return lhs.start < rhs.start
        }
    }

    private func mergeUnifiedSleepSegments(_ segments: [SleepSegment], within gap: TimeInterval) -> [SleepSegment] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted { $0.start < $1.start }
        var merged: [SleepSegment] = []
        var current = sorted[0]

        for segment in sorted.dropFirst() {
            let closeEnough = segment.start.timeIntervalSince(current.end) <= gap
            if closeEnough {
                current = SleepSegment(
                    start: current.start,
                    end: max(current.end, segment.end),
                    stage: current.stage
                )
            } else {
                merged.append(current)
                current = segment
            }
        }

        merged.append(current)
        return merged
    }

    private func mergeSleepStageSegments(_ segments: [SleepSegment], within gap: TimeInterval) -> [SleepSegment] {
        guard !segments.isEmpty else { return [] }
        let allStages: [SleepStage] = [.deep, .core, .rem, .awake]
        var mergedByStage: [SleepSegment] = []

        for stage in allStages {
            let stageSegments = segments
                .filter { $0.stage == stage }
                .sorted { $0.start < $1.start }
            guard !stageSegments.isEmpty else { continue }

            var current = stageSegments[0]
            for segment in stageSegments.dropFirst() {
                let closeEnough = segment.start.timeIntervalSince(current.end) <= gap
                if closeEnough {
                    current = SleepSegment(
                        start: current.start,
                        end: max(current.end, segment.end),
                        stage: current.stage
                    )
                } else {
                    mergedByStage.append(current)
                    current = segment
                }
            }
            mergedByStage.append(current)
        }

        return mergedByStage.sorted { $0.start < $1.start }
    }

    private func sleepStageRenderRank(_ stage: SleepStage) -> Int {
        switch stage {
        case .deep:
            return 0
        case .core:
            return 1
        case .rem:
            return 2
        case .awake:
            return 3
        }
    }

    private func activitySegments(
        for day: Date,
        xDomain: ClosedRange<Date>,
        kind: VitalSample.Kind
    ) -> [ActivitySegment] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let source: [RawVitalSampleRecord]
        switch kind {
        case .walking:
            source = store.walkingSamples
        case .running:
            source = store.runningSamples
        case .sedentary:
            source = store.sedentarySamples
        default:
            source = []
        }

        let points = source
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            .sorted { $0.timestamp < $1.timestamp }

        guard !points.isEmpty else { return [] }

        let maxGap: TimeInterval = 30 * 60
        let minimumDuration: TimeInterval = 10 * 60
        var intervals: [(start: Date, end: Date)] = []

        var segmentStart = points[0].timestamp
        var lastTimestamp = points[0].timestamp
        for point in points.dropFirst() {
            if point.timestamp.timeIntervalSince(lastTimestamp) <= maxGap {
                lastTimestamp = point.timestamp
            } else {
                intervals.append((segmentStart, lastTimestamp))
                segmentStart = point.timestamp
                lastTimestamp = point.timestamp
            }
        }
        intervals.append((segmentStart, lastTimestamp))

        return intervals.compactMap { interval in
            var start = interval.start
            var end = interval.end
            if end.timeIntervalSince(start) < minimumDuration {
                let halfDuration = minimumDuration / 2
                start = start.addingTimeInterval(-halfDuration)
                end = end.addingTimeInterval(halfDuration)
            }
            start = max(start, xDomain.lowerBound)
            end = min(end, xDomain.upperBound)
            guard start < end else { return nil }
            return ActivitySegment(start: start, end: end)
        }
    }

    private func subtractOverlaps(from base: [ActivitySegment], with blockers: [ActivitySegment]) -> [ActivitySegment] {
        guard !base.isEmpty, !blockers.isEmpty else { return base }
        let sortedBlockers = blockers.sorted { $0.start < $1.start }
        var output: [ActivitySegment] = []

        for segment in base {
            var fragments: [ActivitySegment] = [segment]
            for blocker in sortedBlockers {
                var nextFragments: [ActivitySegment] = []
                for fragment in fragments {
                    if blocker.end <= fragment.start || blocker.start >= fragment.end {
                        nextFragments.append(fragment)
                        continue
                    }
                    if blocker.start > fragment.start {
                        nextFragments.append(ActivitySegment(start: fragment.start, end: blocker.start))
                    }
                    if blocker.end < fragment.end {
                        nextFragments.append(ActivitySegment(start: blocker.end, end: fragment.end))
                    }
                }
                fragments = nextFragments
                if fragments.isEmpty { break }
            }
            output.append(contentsOf: fragments.filter { $0.start < $0.end })
        }
        return output
    }

    private func sleepStage(for storedValue: Double) -> SleepStage {
        if storedValue >= 8.5 { return .awake }
        if storedValue >= 3.5 { return .deep }
        if storedValue >= 2.5 { return .rem }
        return .core
    }

    private func sleepStageColor(for stage: SleepStage) -> Color {
        switch stage {
        case .deep:
            return Color(red: 0.23, green: 0.14, blue: 0.77).opacity(0.58)
        case .rem:
            return Color(red: 0.14, green: 0.40, blue: 0.93).opacity(0.52)
        case .core:
            return Color(red: 0.20, green: 0.70, blue: 0.95).opacity(0.46)
        case .awake:
            return Color(red: 0.98, green: 0.60, blue: 0.08).opacity(0.52)
        }
    }

    private func selectedSleepStageSegments(from segments: [SleepSegment]) -> [SleepSegment] {
        return segments.filter { segment in
            switch segment.stage {
            case .deep:
                return showsDeepSleepStage
            case .rem:
                return showsRemSleepStage
            case .core:
                return showsCoreSleepStage
            case .awake:
                return showsAwakeSleepStage
            }
        }
    }

    @ChartContentBuilder
    private func sleepOverlayContent(
        showsSleepOverlay: Bool,
        segments: [SleepSegment],
        yDomain: ClosedRange<Double>,
        style: SleepOverlayStyle
    ) -> some ChartContent {
        if showsSleepOverlay {
            ForEach(segments) { segment in
                RectangleMark(
                    xStart: .value("睡眠开始", segment.start),
                    xEnd: .value("睡眠结束", segment.end),
                    yStart: .value("最低值", yDomain.lowerBound),
                    yEnd: .value("最高值", yDomain.upperBound)
                )
                .foregroundStyle(style == .byStage ? sleepStageColor(for: segment.stage) : Color.blue.opacity(0.40))
            }
        }
    }

    @ChartContentBuilder
    private func activityOverlayContent(
        showsOverlay: Bool,
        segments: [ActivitySegment],
        yDomain: ClosedRange<Double>,
        color: Color,
        systemImage: String
    ) -> some ChartContent {
        if showsOverlay {
            ForEach(segments) { segment in
                RectangleMark(
                    xStart: .value("活动开始", segment.start),
                    xEnd: .value("活动结束", segment.end),
                    yStart: .value("最低值", yDomain.lowerBound),
                    yEnd: .value("最高值", yDomain.upperBound)
                )
                .foregroundStyle(color)
            }
        }
    }

    private func extremaPoints(for points: [DashboardPoint]) -> (min: DashboardPoint, max: DashboardPoint)? {
        guard let minPoint = points.min(by: { $0.value < $1.value }),
              let maxPoint = points.max(by: { $0.value < $1.value }) else {
            return nil
        }
        return (min: minPoint, max: maxPoint)
    }

    private func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func replayLineAnimation(totalPoints: Int) {
        animationTask?.cancel()
        guard totalPoints > 1 else {
            visiblePointCount = totalPoints
            return
        }

        visiblePointCount = 2
        let durationSeconds = 4.8
        let intervalNs = UInt64((durationSeconds / Double(totalPoints)) * 1_000_000_000)

        animationTask = Task {
            var index = 2
            while index <= totalPoints && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: max(1_000_000, intervalNs))
                await MainActor.run {
                    visiblePointCount = index
                }
                index += 1
            }
        }
    }

    private func visiblePoints(from points: [DashboardPoint]) -> [DashboardPoint] {
        guard points.count > 1 else { return points }
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        let safeCount = min(max(2, visiblePointCount), sorted.count)
        return Array(sorted.prefix(safeCount))
    }

    private var usesSoftTrendStyle: Bool {
        selectedKind == .hrv || selectedKind == .respiratoryRate
    }

    private func trendPointColor(for value: Double) -> Color {
        switch selectedKind {
        case .hrv:
            if value >= 60 { return .mint }
            if value >= 30 { return .orange }
            return .pink
        case .respiratoryRate:
            if value < 10 { return Color(red: 0.55, green: 0.05, blue: 0.10) }
            if value <= 20 { return .green }
            return .red
        case .heartRate:
            return .red
        case .sleep:
            return .indigo
        case .standing:
            return .cyan
        case .walking:
            return .green
        case .running:
            return .orange
        case .sedentary:
            return .gray
        }
    }

    private func hrvStatusText(for value: Double) -> String {
        if value >= 60 {
            return "状态优秀"
        } else if value >= 30 {
            return "状态一般"
        } else {
            return "状态偏低"
        }
    }

    private func respiratoryStatusText(for value: Double) -> String {
        if value > 20 {
            return "状态偏高"
        } else if value < 10 {
            return "状态偏低"
        } else {
            return "状态正常"
        }
    }

    private func shortTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func nearestPoint(to date: Date, in points: [DashboardPoint]) -> DashboardPoint? {
        points.min { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(date)) < abs(rhs.timestamp.timeIntervalSince(date))
        }
    }

    private func clearTrendSelection() {
        if selectedKind == .hrv {
            selectedHRVPoint = nil
        } else if selectedKind == .respiratoryRate {
            selectedRespiratoryPoint = nil
        }
    }

}

private struct DashboardPoint: Identifiable {
    let id: TimeInterval
    let timestamp: Date
    let value: Double
}

private struct ChartStats {
    let min: Double
    let max: Double
    let avg: Double
}

private struct SleepSegment: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let stage: SleepStage

    var midpoint: Date {
        Date(timeIntervalSinceReferenceDate: (start.timeIntervalSinceReferenceDate + end.timeIntervalSinceReferenceDate) / 2)
    }
}

private struct ActivitySegment: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date

    var midpoint: Date {
        Date(timeIntervalSinceReferenceDate: (start.timeIntervalSinceReferenceDate + end.timeIntervalSinceReferenceDate) / 2)
    }
}

private enum SleepStage {
    case deep
    case rem
    case core
    case awake
}

private enum SleepOverlayStyle {
    case unified
    case byStage
}

struct HistoryView: View {
    @ObservedObject var store: VitalStore
    @Binding var exportText: String
    @Binding var showExporter: Bool
    @State private var selectedKind: VitalSample.Kind = .heartRate
    @State private var currentPage = 1
    private let pageSize = 10

    var body: some View {
        List {
            Section("类型") {
                Picker("历史类型", selection: $selectedKind) {
                    Text("心率历史").tag(VitalSample.Kind.heartRate)
                    Text("呼吸历史").tag(VitalSample.Kind.respiratoryRate)
                    Text("HRV历史").tag(VitalSample.Kind.hrv)
                    Text("睡眠历史").tag(VitalSample.Kind.sleep)
                    Text("步行历史").tag(VitalSample.Kind.walking)
                    Text("跑步历史").tag(VitalSample.Kind.running)
                    Text("静止历史").tag(VitalSample.Kind.sedentary)
                }
                .pickerStyle(.menu)
            }

            Section("\(historyTitle)（每页 10 条）") {
                if currentPageSessions.isEmpty {
                    Text("暂无记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(currentPageSessions, id: \.id) { session in
                        NavigationLink {
                            RawSampleDetailView(session: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(session.start, style: .date) \(session.start, style: .time)")
                                Text("\(sessionLabel(session)) · 共 \(session.samples.count) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("导出 CSV") {
                    exportText = csvText(from: store.records)
                    showExporter = true
                }
            }
        }
        .navigationTitle("历史")
        .fileExporter(
            isPresented: $showExporter,
            document: TextDocument(text: exportText),
            contentType: .commaSeparatedText,
            defaultFilename: "vitaltrack_export"
        ) { _ in }
        .safeAreaInset(edge: .bottom) {
            paginationBar
                .background(.ultraThinMaterial)
        }
        .onAppear {
            currentPage = 1
        }
        .onChange(of: selectedKind) { _, _ in
            currentPage = 1
        }
        .onChange(of: currentSampleList.count) { _, _ in
            if currentPage > totalPages {
                currentPage = totalPages
            }
        }
    }

    private var paginationBar: some View {
        HStack {
            Button("上一页") {
                guard currentPage > 1 else { return }
                currentPage -= 1
            }
            .disabled(currentPage <= 1)

            Spacer()
            Text("第 \(currentPage) / \(totalPages) 页")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()

            Button("下一页") {
                guard currentPage < totalPages else { return }
                currentPage += 1
            }
            .disabled(currentPage >= totalPages)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var currentSampleList: [RawVitalSampleRecord] {
        switch selectedKind {
        case .heartRate:
            return store.heartRateSamples.sorted { $0.timestamp > $1.timestamp }
        case .respiratoryRate:
            return store.respiratorySamples.sorted { $0.timestamp > $1.timestamp }
        case .hrv:
            return store.hrvSamples.sorted { $0.timestamp > $1.timestamp }
        case .sleep:
            return store.sleepSamples.sorted { $0.timestamp > $1.timestamp }
        case .standing:
            return []
        case .walking:
            return store.walkingSamples.sorted { $0.timestamp > $1.timestamp }
        case .running:
            return store.runningSamples.sorted { $0.timestamp > $1.timestamp }
        case .sedentary:
            return store.sedentarySamples.sorted { $0.timestamp > $1.timestamp }
        }
    }

    private var historyTitle: String {
        switch selectedKind {
        case .heartRate:
            return "心率历史"
        case .respiratoryRate:
            return "呼吸历史"
        case .hrv:
            return "HRV历史"
        case .sleep:
            return "睡眠历史"
        case .standing:
            return "状态历史"
        case .walking:
            return "步行历史"
        case .running:
            return "跑步历史"
        case .sedentary:
            return "静止历史"
        }
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(sessionList.count) / Double(pageSize))))
    }

    private var sessionList: [RawSampleSession] {
        let sortedAsc = currentSampleList.sorted { $0.timestamp < $1.timestamp }
        guard !sortedAsc.isEmpty else { return [] }

        let calendar = Calendar.current
        let intervalSeconds: Int = selectedKind == .heartRate ? 15 * 60 : 60 * 60
        let grouped = Dictionary(grouping: sortedAsc) { sample in
            let dayStart = calendar.startOfDay(for: sample.timestamp)
            let offset = Int(sample.timestamp.timeIntervalSince(dayStart))
            let bucketStartOffset = (offset / intervalSeconds) * intervalSeconds
            return dayStart.addingTimeInterval(TimeInterval(bucketStartOffset))
        }

        let sessions = grouped.keys.sorted().compactMap { key -> RawSampleSession? in
            guard let samples = grouped[key], !samples.isEmpty else { return nil }
            return buildSession(from: samples, forcedStart: key, intervalSeconds: intervalSeconds)
        }
        return sessions.sorted { $0.start > $1.start }
    }

    private var currentPageSessions: [RawSampleSession] {
        guard !sessionList.isEmpty else { return [] }
        let start = (currentPage - 1) * pageSize
        guard start < sessionList.count else { return [] }
        let end = min(start + pageSize, sessionList.count)
        return Array(sessionList[start..<end])
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }

    private func csvText(from records: [VitalMinuteRecord]) -> String {
        var rows = ["timestamp_minute,heart_rate_avg,heart_rate_min,heart_rate_max,resp_rate_avg,sample_count,source,quality_flag"]
        let formatter = ISO8601DateFormatter()
        for record in records.sorted(by: { $0.timestampMinute < $1.timestampMinute }) {
            let columns: [String] = [
                formatter.string(from: record.timestampMinute),
                valueToString(record.heartRateAvg),
                valueToString(record.heartRateMin),
                valueToString(record.heartRateMax),
                valueToString(record.respiratoryRateAvg),
                String(record.sampleCount),
                record.source,
                record.qualityFlag
            ]
            rows.append(columns.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func valueToString(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private func buildSession(from samples: [RawVitalSampleRecord], forcedStart: Date, intervalSeconds: Int) -> RawSampleSession {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        return RawSampleSession(
            id: sorted.first?.id ?? Int64.random(in: .min ... .max),
            kind: sorted.first?.kind ?? .heartRate,
            start: forcedStart,
            end: forcedStart.addingTimeInterval(TimeInterval(intervalSeconds)),
            samples: sorted
        )
    }

    private func sessionLabel(_ session: RawSampleSession) -> String {
        let duration = max(1, Int(session.end.timeIntervalSince(session.start)))
        switch session.kind {
        case .heartRate:
            return "心率时段 \(duration) 秒"
        case .respiratoryRate:
            return "呼吸时段 \(duration) 秒"
        case .hrv:
            return "HRV时段 \(duration) 秒"
        case .sleep:
            return "睡眠时段 \(duration) 秒"
        case .standing, .walking, .running, .sedentary:
            return "状态时段 \(duration) 秒"
        }
    }

}

private struct VitalRecordDetailView: View {
    let record: VitalMinuteRecord

    var body: some View {
        List {
            Section("时间") {
                LabeledContent("日期", value: dateString(record.timestampMinute))
                LabeledContent("时间", value: timeString(record.timestampMinute))
            }

            Section("心率") {
                LabeledContent("平均", value: metricString(record.heartRateAvg, unit: "bpm"))
                LabeledContent("最小", value: metricString(record.heartRateMin, unit: "bpm"))
                LabeledContent("最大", value: metricString(record.heartRateMax, unit: "bpm"))
            }

            Section("呼吸") {
                LabeledContent("平均", value: metricString(record.respiratoryRateAvg, unit: "次/分"))
            }

            Section("数据质量") {
                LabeledContent("样本数", value: String(record.sampleCount))
                LabeledContent("来源设备", value: record.source)
                LabeledContent("质量标记", value: record.qualityFlag)
            }
        }
        .navigationTitle("记录详情")
    }

    private func metricString(_ value: Double?, unit: String) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f %@", value, unit)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct RawSampleSession: Identifiable, Hashable {
    let id: Int64
    let kind: VitalSample.Kind
    let start: Date
    let end: Date
    let samples: [RawVitalSampleRecord]
}

private struct RawSampleDetailView: View {
    let session: RawSampleSession

    var body: some View {
        List {
            Section("时间") {
                LabeledContent("开始", value: dateTimeString(session.start))
                LabeledContent("结束", value: dateTimeString(session.end))
                LabeledContent("时长", value: "\(max(1, Int(session.end.timeIntervalSince(session.start)))) 秒")
            }

            Section("采集点明细") {
                ForEach(session.samples, id: \.id) { item in
                    HStack {
                        Text(timeString(item.timestamp))
                        Spacer()
                        if session.kind == .heartRate {
                            Text("\(String(format: "%.1f", item.value)) bpm")
                        } else if session.kind == .respiratoryRate {
                            Text("\(String(format: "%.1f", item.value)) 次/分")
                        } else if session.kind == .hrv {
                            Text("\(String(format: "%.1f", item.value)) ms")
                        } else if session.kind == .sleep {
                            Text("睡眠")
                        } else {
                            Text("状态")
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .navigationTitle(detailTitle)
    }

    private var detailTitle: String {
        switch session.kind {
        case .heartRate:
            return "心率时段详情"
        case .respiratoryRate:
            return "呼吸时段详情"
        case .hrv:
            return "HRV时段详情"
        case .sleep:
            return "睡眠时段详情"
        case .standing, .walking, .running, .sedentary:
            return "状态详情"
        }
    }

    private func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct SettingsView: View {
    @ObservedObject var store: VitalStore

    var body: some View {
        List {
            Section("权限状态") {
                Text(store.authorizationStatus)
            }

            Section("同步") {
                Button(store.isSyncing ? "同步中..." : "立即同步") {
                    Task {
                        await store.syncRecent7Days()
                    }
                }
                .disabled(store.isSyncing)
            }

            if let error = store.lastError {
                Section("错误") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("设置")
    }
}

private struct MetricRow: View {
    let title: String
    let value: Double?
    let unit: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { String(format: "%.1f %@", $0, unit) } ?? "--")
                .foregroundStyle(.secondary)
        }
    }
}

