import Darwin

/// Process-wide signal policy for the two processes that host the engine.
public enum ProcessSignals {
    /// A write to a socket or pipe whose reader has gone raises SIGPIPE, and
    /// its default action ends the process — the daemon (launchd restarts it
    /// cold) or the app hosting the engine (the menu bar item vanishes).
    /// `SO_NOSIGPIPE` on the control socket (v0.92.x) did not stop it:
    /// usaged still died "of SIGPIPE, sent by usaged" on a build that had it
    /// (2026-10-29), from a write nobody identified. Ignoring it process-wide
    /// turns every such write into an EPIPE error its caller already handles.
    ///
    /// Hosts only. `usage-cli` keeps the default: a CLI piped into `head`
    /// should end quietly when the reader leaves, which is what Unix does.
    public static func ignoreBrokenPipes() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// True when SIGPIPE is currently ignored — what the tests pin.
    public static var brokenPipesIgnored: Bool {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        // SIG_IGN is the handler value 1; function pointers don't compare.
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == 1
    }
}
