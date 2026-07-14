import Darwin
import Foundation

/// A single app's recent energy impact, used for the "high energy usage"
/// readout. `energyImpact` approximates Activity Monitor's energy-impact score
/// by combining CPU load (percent of one core) with idle wakeups per second for
/// the app and its helper processes. It is a relative indicator, not Apple's
/// exact (private) value.
struct AppEnergyUsage: Identifiable, Equatable, Sendable {
    let appPath: String
    let name: String
    let energyImpact: Double

    var id: String { appPath }
}

/// Samples per-process CPU time and aggregates it per `.app` bundle so that
/// multi-process apps (browsers and their renderers, for example) are counted
/// together. CPU usage is the dominant, publicly measurable proxy for energy
/// impact; true per-app wattage is not exposed by a public macOS API.
@MainActor
final class ProcessEnergySampler {
    private struct Sample {
        let cpuNanoseconds: UInt64
        let idleWakeups: UInt64
    }

    /// Weight applied to idle wakeups per second when approximating Activity
    /// Monitor's energy impact. CPU load (percent of one core) is the dominant
    /// term; wakeups add a secondary cost so chatty, low-CPU apps still register.
    private let idleWakeupWeight = 0.45

    private var previous: [pid_t: Sample] = [:]
    private var previousSampleTime: Date?

    func sample(limit: Int = 3, minimumImpact: Double = 0.1, now: Date = .now) -> [AppEnergyUsage] {
        let pids = Self.runningPIDs()
        let wallSeconds = previousSampleTime.map { now.timeIntervalSince($0) } ?? 0

        var current: [pid_t: Sample] = [:]
        current.reserveCapacity(pids.count)
        var perApp: [String: (name: String, cpuDelta: UInt64, wakeupDelta: UInt64)] = [:]

        for pid in pids {
            guard let sample = Self.metrics(pid: pid) else {
                continue
            }
            current[pid] = sample

            guard wallSeconds > 0,
                  let previousSample = previous[pid],
                  sample.cpuNanoseconds >= previousSample.cpuNanoseconds,
                  let appPath = Self.appBundlePath(pid: pid) else {
                continue
            }

            let cpuDelta = sample.cpuNanoseconds - previousSample.cpuNanoseconds
            let wakeupDelta = sample.idleWakeups >= previousSample.idleWakeups
                ? sample.idleWakeups - previousSample.idleWakeups
                : 0
            let existing = perApp[appPath]
            perApp[appPath] = (
                existing?.name ?? Self.appName(fromBundlePath: appPath),
                (existing?.cpuDelta ?? 0) + cpuDelta,
                (existing?.wakeupDelta ?? 0) + wakeupDelta
            )
        }

        previous = current
        previousSampleTime = now

        guard wallSeconds > 0 else {
            return []
        }

        let intervalNanoseconds = wallSeconds * 1_000_000_000

        return perApp
            .map { path, value in
                let cpuPercent = Double(value.cpuDelta) / intervalNanoseconds * 100
                let wakeupsPerSecond = Double(value.wakeupDelta) / wallSeconds
                return AppEnergyUsage(
                    appPath: path,
                    name: value.name,
                    energyImpact: cpuPercent + wakeupsPerSecond * idleWakeupWeight
                )
            }
            .filter { $0.energyImpact >= minimumImpact }
            .sorted { $0.energyImpact > $1.energyImpact }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - System access

    private static func runningPIDs() -> [pid_t] {
        let suggested = proc_listallpids(nil, 0)
        guard suggested > 0 else {
            return []
        }

        var pids = [pid_t](repeating: 0, count: Int(suggested) + 64)
        let returned = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard returned > 0 else {
            return []
        }

        return pids.filter { $0 > 0 }
    }

    private static func metrics(pid: pid_t) -> Sample? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }

        guard result == 0 else {
            return nil
        }

        return Sample(
            cpuNanoseconds: usage.ri_user_time + usage.ri_system_time,
            idleWakeups: usage.ri_pkg_idle_wkups
        )
    }

    private static func appBundlePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a C macro that is not
        // imported into Swift, so its value is inlined here.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }

        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else {
            return nil
        }

        let end = path.index(range.lowerBound, offsetBy: 4)
        return String(path[..<end])
    }

    private static func appName(fromBundlePath path: String) -> String {
        let component = (path as NSString).lastPathComponent
        if component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return component
    }
}
