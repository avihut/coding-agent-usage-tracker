import Darwin
import Foundation

/// Stage timings from process start to the first COMPLETE publish — every
/// account with meters, a landed scan and a forecast pass. One log line per
/// stage, each stamped with the milliseconds since the process started (the
/// kernel's own start time, so the time before `main()` is in the first
/// line), so a slow start says where it went instead of "it takes ages".
///
/// A host process sets `sink` once, early (usaged logs to stderr; tests
/// collect). With no sink every mark is a no-op. Stages fire once each: a
/// mark repeated later in the process (a second engine reconcile, a reprobe)
/// is dropped, so the trace describes the START and nothing after it.
@MainActor
public final class StartupTrace {
    public static let shared = StartupTrace()

    /// Where marks go. Nil = tracing off.
    public var sink: ((String) -> Void)?
    /// Set when the trace reached `complete` — nothing marks after that.
    public private(set) var isComplete = false

    private let processStart: Date
    private var seen: Set<String> = []

    init(processStart: Date = StartupTrace.processStartDate() ?? Date()) {
        self.processStart = processStart
    }

    /// Milliseconds since the process started.
    public func elapsedMilliseconds(now: Date = Date()) -> Int {
        Int((now.timeIntervalSince(processStart) * 1000).rounded())
    }

    /// Logs `stage` once, with an optional detail.
    public func mark(_ stage: String, _ detail: String? = nil, now: Date = Date()) {
        guard let sink, !isComplete, !seen.contains(stage) else { return }
        seen.insert(stage)
        let suffix = detail.map { " — \($0)" } ?? ""
        sink("startup +\(elapsedMilliseconds(now: now))ms \(stage)\(suffix)")
    }

    /// The last mark: everything after this is steady state.
    public func complete(_ detail: String? = nil, now: Date = Date()) {
        mark("complete", detail, now: now)
        if sink != nil { isComplete = true }
    }

    /// The kernel's record of when this process started (`p_starttime`),
    /// which includes dyld and everything before `main()`.
    nonisolated public static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
    }
}
