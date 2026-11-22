import Dispatch

/// The engine's two speeds (2026-11-21). Every HEAVY off-main hop — the
/// transcript scans and their cached passes, decoding, forecasts, presence
/// probes, discovery — runs at `heavy`; the responsiveness path — the
/// digest publisher, the control socket's answers — runs at `responsive`.
///
/// The host process itself runs at app priority (`ProcessType` Interactive,
/// `LaunchAgentInstaller.processType`), so the heartbeat, the publish and
/// the socket keep getting CPU on a saturated Mac. The heavy work stays at
/// UTILITY, beneath the person's agents (default QoS, priority ~31), so it
/// takes the CPU they leave rather than competing for it. Not `.background`:
/// background QoS is priority 4, and a scan there never finished under load
/// — exactly the 22:30 starvation (docs/DAEMON.md "Priority").
///
/// A new poller or scanner in the engine takes its priority from here, so a
/// retune is one line.
public enum EngineWork {
    public static let heavy: TaskPriority = .utility
    public static let heavyQoS: DispatchQoS = .utility
    public static let responsiveQoS: DispatchQoS = .userInitiated
    /// The ONE bounded piece of start-up work a person is waiting on: the
    /// cached pass that puts the previous run's activity on screen
    /// (`LocalActivitySource.cachedScan` — a cache decode, no stat, no
    /// parse). Once per engine start, and short; the full re-validation that
    /// follows it is `heavy`.
    public static let startup: TaskPriority = .userInitiated
    /// An agent's own tool the host spawns (the quota probe's child) runs
    /// UNCLAMPED: no QoS attribute, so default priority (31), like the
    /// agents and anything the person starts — and this is the thread that
    /// watches it. Measured 2026-11-22 with every core saturated: a
    /// utility-clamped child (priority 20) took `--version` to 10.4 s and
    /// `/quota` to 14.3 s; unclamped, under 0.8 s and 3.1 s, for the same
    /// 0.1–0.5 s of CPU, at most every 10 minutes
    /// (docs/plans/antigravity-probe-under-load.md). The only clamps
    /// `posix_spawnattr_set_qos_class_np` takes are utility and background,
    /// so SwiftLint forbids the call.
    public static let agentCommandQoS: DispatchQoS = .default
}
