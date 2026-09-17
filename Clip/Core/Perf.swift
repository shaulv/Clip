import Foundation

/// Counters and timings, so a performance claim can carry a number.
///
/// The whole point of this file is that "it feels faster" is not a result. The
/// last round of search work in this project measured 664.8ms, "fixed" it, and
/// only a re-measurement revealed the fix had introduced a 245ms regression of
/// its own. Numbers caught that. Reading the code did not.
///
/// Inert unless `CLIP_PERF=1`, and the guard is a single stored Bool rather
/// than an environment lookup, so the cost on the real app is one branch that
/// the optimiser is free to predict.
enum Perf {

    /// Read once at startup. An environment lookup per call would itself be the
    /// slow thing being measured.
    static let isEnabled = ProcessInfo.processInfo.environment["CLIP_PERF"] == "1"

    private static var counters: [String: Int] = [:]
    private static var samples: [String: [Double]] = [:]

    /// Records that something happened once.
    ///
    /// The counters matter as much as the timings: knowing that pressing the
    /// down arrow re-runs the filter pipeline eleven times explains the lag in
    /// a way that a millisecond figure never would.
    @inline(__always)
    static func count(_ key: String) {
        if key == "visibleItems" { visibleItemsRuns &+= 1 }
        guard isEnabled else { return }
        counters[key, default: 0] += 1
    }

    /// Times `work` and files the result under `key`.
    @inline(__always)
    static func measure<T>(_ key: String, _ work: () -> T) -> T {
        guard isEnabled else { return work() }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        samples[key, default: []].append(ms)
        return result
    }

    /// Files an externally measured duration.
    static func record(_ key: String, ms: Double) {
        guard isEnabled else { return }
        samples[key, default: []].append(ms)
    }

    /// How many times the visible-list pipeline has run.
    ///
    /// Exposed separately from `report` because the derivation audit asserts on
    /// it directly: the point of the cache is that moving the selection causes
    /// zero recomputations, and that is a claim worth failing a test over.
    /// Counted whether or not `CLIP_PERF` is set, so the audit works in an
    /// ordinary QA run.
    static var visibleItemsRuns: Int = 0

    static func reset() {
        counters.removeAll()
        samples.removeAll()
    }

    /// Everything gathered, as the probe wants to read it.
    ///
    /// p95 is reported alongside the median because a median hides exactly the
    /// stutter a user notices: a list that is smooth nineteen keystrokes out of
    /// twenty still reads as laggy.
    static var report: [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in counters { out["count.\(key)"] = value }
        for (key, values) in samples {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { continue }
            out["ms.\(key).median"] = round(sorted[sorted.count / 2] * 100) / 100
            out["ms.\(key).p95"] = round(sorted[min(sorted.count - 1,
                                                    Int(Double(sorted.count) * 0.95))] * 100) / 100
            out["ms.\(key).max"] = round((sorted.last ?? 0) * 100) / 100
            out["ms.\(key).n"] = sorted.count
        }
        return out
    }

    /// The app's own memory, in MB, for the leak gate.
    ///
    /// `phys_footprint`, which is what Activity Monitor calls Memory and what
    /// the system uses to decide who is using too much. NOT `resident_size`:
    /// that counts every shared framework page mapped into the process, so it
    /// reported 223 MB for an app whose real footprint was 33.8 MB, and it
    /// moved with which system libraries happened to be paged in. A metric
    /// that large and that noisy cannot show a leak - it hides one.
    static var residentMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size)
                  / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        return round(Double(info.phys_footprint) / 1_048_576 * 10) / 10
    }
}
