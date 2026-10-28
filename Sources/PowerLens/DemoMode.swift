import Foundation

/// Scripted readings for README screenshots: launch a debug build with
/// `--demo`. Release builds ignore the flag, so they never show made-up values.
enum DemoMode {
    static let isRequested: Bool = {
        #if DEBUG
        CommandLine.arguments.contains("--demo")
        #else
        false
        #endif
    }()
}

#if DEBUG
extension DemoMode {
    /// History goes to a fresh temporary database, never the user's.
    @MainActor
    static func makeStore() -> PowerLensStore {
        let scenario = DemoScenario(now: Date())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PowerLensDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        return PowerLensStore(
            telemetryReader: DemoTelemetryReader(scenario: scenario),
            historyStore: DemoHistoryStore(
                store: HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3")),
                samples: scenario.history
            ),
            energySampler: DemoEnergySampler(),
            energyModeReader: DemoEnergyModeReader(),
            systemCompatibilityRecorder: DemoCompatibilityRecorder()
        )
    }
}

/// A month of plausible use ending with the charger plugged in half an hour
/// ago: on battery during work blocks, charging or holding otherwise.
struct DemoScenario: Sendable {
    static let designCapacityMah = 6_249
    static let packWh = 72.0

    let history: [TelemetrySnapshot]
    let finalLevel: Double

    init(now: Date) {
        var random = SplitMix64(seed: 2026)
        var samples: [TelemetrySnapshot] = []
        var level = 80.0
        var time = now.addingTimeInterval(-30 * 86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let apps = [("Xcode", "com.apple.dt.Xcode"), ("Safari", "com.apple.Safari"), ("Music", "com.apple.Music")]

        while time < now {
            let remaining = now.timeIntervalSince(time)
            // Older history is sparser; the last day is minute by minute.
            let step: TimeInterval = remaining > 86_400 ? 600 : 60
            let hour = calendar.component(.hour, from: time)
            // The last six hours follow the same script whatever the clock
            // says: charge, a work block on battery, then the charger.
            let plugged: Bool
            if remaining <= 30 * 60 {
                plugged = true
            } else if remaining <= 4 * 3_600 {
                plugged = false
            } else if remaining <= 6 * 3_600 {
                plugged = true
            } else {
                plugged = !(9..<13).contains(hour) && !(15..<18).contains(hour)
            }
            let idle = (0..<8).contains(hour) && remaining > 6 * 3_600
            let spike = random.next(in: 0...1) > 0.93 ? random.next(in: 12...24) : 0
            let load = idle
                ? 3 + random.next(in: 0...1.5)
                : (plugged ? 9 + random.next(in: 0...9) : 6 + random.next(in: 0...7)) + spike
            let batteryW: Double
            if plugged {
                batteryW = level >= 99.5 ? 0 : (level < 80 ? 27 : max(2, 27 * (100 - level) / 20))
            } else {
                batteryW = -load
            }
            level = min(100, max(5, level + batteryW * step / 3_600 / Self.packWh * 100))
            let app = apps[Int(random.next(in: 0...2.99))]
            let age = remaining / 86_400
            samples.append(Self.snapshot(
                at: time, level: level, plugged: plugged, batteryW: batteryW, loadW: load,
                temperature: 30 + (plugged && batteryW > 5 ? 2.2 : 0) + random.next(in: 0...0.8),
                fullChargeCapacity: 5_804 + Int(age * 4.5), cycles: 214 - Int(age * 0.8),
                app: app
            ))
            time += step
        }
        history = samples
        finalLevel = level
    }

    /// Steady values, so a screenshot never catches digits mid-roll.
    func liveSnapshot(at date: Date) -> TelemetrySnapshot {
        Self.snapshot(
            at: date, level: finalLevel, plugged: true, batteryW: 27.6, loadW: 21.4,
            temperature: 32.1, fullChargeCapacity: 5_804, cycles: 214,
            app: ("Xcode", "com.apple.dt.Xcode")
        )
    }

    private static func snapshot(
        at date: Date,
        level: Double,
        plugged: Bool,
        batteryW: Double,
        loadW: Double,
        temperature: Double,
        fullChargeCapacity: Int,
        cycles: Int,
        app: (name: String, bundleID: String)
    ) -> TelemetrySnapshot {
        let voltage = 11.9 + level / 100 * 0.9
        let charging = plugged && batteryW > 0
        let input = plugged ? loadW + max(0, batteryW) + 0.4 : nil
        return TelemetrySnapshot(
            timestamp: date,
            batteryLevel: level.rounded(),
            powerSource: plugged ? .ac : .battery,
            isCharging: charging,
            isCharged: plugged && !charging,
            externalConnected: plugged,
            timeToEmptyMinutes: plugged ? nil : Int(level / 100 * packWh / loadW * 60),
            timeToFullMinutes: charging ? Int((100 - level) * 1.6) : nil,
            designCapacityMah: designCapacityMah,
            fullChargeCapacityMah: fullChargeCapacity,
            nominalCapacityMah: fullChargeCapacity + 86,
            cycleCount: cycles,
            designCycleCount: 1_000,
            batteryHealthText: "Normal",
            batteryHealthCondition: nil,
            batteryTemperatureC: temperature,
            batteryVoltageV: voltage,
            // `batteryW` is positive while charging. Like the sensors, current
            // is positive while charging and SMC power while discharging.
            batteryCurrentA: batteryW / voltage,
            batteryPowerW: -batteryW,
            batteryPowerSource: .directTelemetry,
            adapterDescription: plugged ? "96W USB-C Power Adapter" : nil,
            adapterMaxPowerW: plugged ? 96 : nil,
            adapterInputPowerW: input,
            adapterVoltageV: plugged ? 20.2 : nil,
            adapterCurrentA: input.map { $0 / 20.2 },
            systemLoadW: loadW,
            powerMeasurementSetSource: .smc,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "DEMO0000000000000",
            frontmostAppBundleID: app.bundleID,
            frontmostAppName: app.name,
            chargingPolicyStatus: .inactive
        )
    }
}

struct DemoTelemetryReader: TelemetryReading {
    let scenario: DemoScenario

    func readSnapshot(preference: TelemetryEnginePreference) async throws -> TelemetryReadResult {
        TelemetryReadResult(snapshot: scenario.liveSnapshot(at: Date()), activeEngine: .livePrecision)
    }
}

/// Fills the temporary database before the first query reaches it.
actor DemoHistoryStore: HistoryStoring {
    private let store: HistoryStore
    private let samples: [TelemetrySnapshot]
    private var seeding: Task<Void, Error>?

    init(store: HistoryStore, samples: [TelemetrySnapshot]) {
        self.store = store
        self.samples = samples
    }

    private func seeded() async throws -> HistoryStore {
        if seeding == nil {
            let store = store
            let samples = samples
            seeding = Task {
                for sample in samples {
                    try await store.append(sample)
                }
            }
        }
        try await seeding?.value
        return store
    }

    func latestSampleTimestamp() async throws -> Date? {
        try await seeded().latestSampleTimestamp()
    }

    func loadRecent(since cutoffDate: Date) async throws -> [TelemetrySnapshot] {
        try await seeded().loadRecent(since: cutoffDate)
    }

    func loadRecentRecords(since cutoffDate: Date) async throws -> [StoredTelemetrySample] {
        try await seeded().loadRecentRecords(since: cutoffDate)
    }

    func append(_ snapshot: TelemetrySnapshot) async throws {
        try await seeded().append(snapshot)
    }

    func purge(olderThan cutoffDate: Date, rollupBucketSeconds: Int?) async throws {
        try await seeded().purge(olderThan: cutoffDate, rollupBucketSeconds: rollupBucketSeconds)
    }

    func removeExpiredBackups(now: Date, discardingAll: Bool) async throws {
        try await seeded().removeExpiredBackups(now: now, discardingAll: discardingAll)
    }

    func summary(for range: DateInterval) async throws -> HistorySummary {
        try await seeded().summary(for: range)
    }

    func aggregatedSeries(for range: DateInterval, bucketSeconds: Int) async throws -> [AggregatedTelemetryPoint] {
        try await seeded().aggregatedSeries(for: range, bucketSeconds: bucketSeconds)
    }

    func rollupSeries(for range: DateInterval) async throws -> [AggregatedTelemetryPoint] {
        try await seeded().rollupSeries(for: range)
    }

    func batteryHealthTrend(since cutoffDate: Date) async throws -> [BatteryHealthPoint] {
        try await seeded().batteryHealthTrend(since: cutoffDate)
    }

    func loadInsights(for range: HistoryRange, now: Date) async throws -> InsightsData {
        try await seeded().loadInsights(for: range, now: now)
    }
}

struct DemoEnergySampler: ProcessEnergySampling {
    func sample(now: Date) async -> [AppEnergyUsage] {
        [
            AppEnergyUsage(appPath: "/Applications/Xcode.app", name: "Xcode", energyImpact: 38.2),
            AppEnergyUsage(appPath: "/Applications/Safari.app", name: "Safari", energyImpact: 12.6),
            AppEnergyUsage(appPath: "/System/Applications/Music.app", name: "Music", energyImpact: 3.1),
        ]
    }
}

struct DemoEnergyModeReader: EnergyModeReading {
    func read(lowPowerFallback: Bool) async -> EnergyMode {
        .automatic
    }
}

struct DemoCompatibilityRecorder: SystemCompatibilityRecording {
    func record(_ diagnostic: SystemCompatibilityDiagnostic, observedAt: Date) async {}
}

/// Deterministic, so every run draws the same history.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + Double(z >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
#endif
