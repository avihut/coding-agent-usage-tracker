import Foundation

/// What a face asks the host for, and the control socket every face speaks
/// through. Split from `MeteringHost` itself at the 600-line rule: the type
/// above owns harnesses, accounts, engines, focus and the digest; this half
/// owns the verbs.
extension MeteringHost {
    // MARK: - Faces

    /// `profile` is a `ProfileKey`; nil means the focused account's engine.
    public func refresh(_ reason: UsageEngine.RefreshReason, profile: String? = nil) {
        (profile.flatMap { engines[$0] } ?? focusedEngine)?.refresh(reason)
    }

    public func thresholdsChanged() {
        for engine in engines.values { engine.thresholdsChanged() }
        if engines.isEmpty { republish() }
    }

    /// The socket's `settingsChanged`: thresholds and everything else a host
    /// reads out of the shared defaults domain — including which harnesses
    /// the person hid, which is why hiding needs no verb of its own.
    public func settingsChanged() {
        for engine in engines.values { engine.thresholdsChanged() }
        if hidden != HarnessRoster.hidden(from: defaults) {
            reloadProfiles()
        } else if engines.isEmpty {
            republish()
        }
    }

    public func setActiveInterval(_ interval: TimeInterval) {
        for engine in engines.values { engine.setActiveInterval(interval) }
        if engines.isEmpty {
            let clamped = min(max(TriggerGate.floor, interval), AdaptiveCadence.maxActiveInterval)
            defaults.set(clamped, forKey: UsageEngine.intervalKey)
            republish()
        }
    }

    public func scanActivity(force: Bool = false) {
        for engine in engines.values { engine.scanActivity(force: force) }
    }

    public func sessionDetail(id: String, profile: String? = nil) async -> SessionDetail? {
        guard let engine = profile.flatMap({ engines[$0] }) ?? focusedEngine else { return nil }
        return await engine.sessionDetail(id: id)
    }

    /// Pricing and status belong to a harness. With none named, every
    /// metered harness refreshes — what a "Refresh now" button means when
    /// the rates list spans all of them.
    public func refreshPricingNow(harness: String? = nil) {
        if let harness {
            serviceRegistry[harness]?.refreshPricingNow()
        } else {
            serviceRegistry.refreshPricingNow()
        }
    }

    public func refreshServiceStatus(harness: String? = nil) {
        if let harness {
            serviceRegistry[harness]?.refreshServiceStatus()
        } else {
            serviceRegistry.refreshServiceStatus()
        }
    }

    public func checkForUpdates() { updateChecker?.checkNow() }

    /// The pricing table of one harness — what its rates section lists.
    public func pricing(harness: String) -> PricingTable? {
        services(forHarness: harness)?.pricing
    }

    // One face belongs to one ACCOUNT of one HARNESS, so the vendor-level
    // cards it renders are that harness's — never the focused harness's
    // (0.101.0). The unqualified properties above stay the focused
    // harness's, which is what the top level of the digest projects.

    public func serviceStatus(harness: String) -> ServiceStatusCard? {
        services(forHarness: harness)?.serviceStatus
    }

    public func isRefreshingPricing(harness: String) -> Bool {
        services(forHarness: harness)?.isRefreshingPricing ?? false
    }

    public func pricingRefreshError(harness: String) -> String? {
        services(forHarness: harness)?.pricingRefreshError
    }

    /// This harness's pending notices as the digest phrased them, ids
    /// qualified so a dismissal reaches its own ledger.
    public func notices(harness: String) -> NoticesCard? {
        guard let listed = digest?.harnesses else {
            return harness == focusedHarnessID ? notices : nil
        }
        return listed.first { $0.id == harness }?.notices
    }

    public func outages(harness: String) -> [OutageSpan] {
        guard let listed = digest?.harnesses else {
            return harness == focusedHarnessID ? outages : []
        }
        return listed.first { $0.id == harness }?.outages ?? []
    }

    /// A face rendered these pending notices. Seen is not dismissed. Ids are
    /// the digest's, so each one lands in its own harness's ledger.
    public func markNoticesSeen(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        serviceRegistry.markSeen(ids)
    }

    /// The person's ×. Refused for an ongoing notice. Dismissing a
    /// discovered home's offer also ignores that home (D2).
    @discardableResult
    public func dismissNotice(id: String) -> Bool {
        let routed = NoticeRouting.split(id)
        if let home = discoveredByHarness[routed.providerID]?.first(where: {
            Notice.profileFoundID(profileID: $0.profileID) == routed.id
        }) {
            ignore(home, providerID: routed.providerID)
        }
        return serviceRegistry.dismiss(id)
    }

    public func dismissAllNotices() {
        for row in roster.rows {
            for home in discoveredByHarness[row.id] ?? []
            where serviceRegistry[row.id]?.notices.notices.contains(where: {
                $0.id == Notice.profileFoundID(profileID: home.profileID) && $0.isPending
            }) == true {
                ignore(home, providerID: row.id)
            }
        }
        serviceRegistry.dismissAll()
    }

    public var statusSummary: String {
        let harnesses = roster.rows.map { $0.shown ? $0.id : "\($0.id) (hidden)" }
        let listed = harnesses.count > 1
            ? "harnesses \(harnesses.joined(separator: ", ")), " : ""
        return "\(configuration.kind.rawValue) pid \(ProcessInfo.processInfo.processIdentifier), "
            + "provider \(provider.id), v\(AppIdentity.version), "
            + listed
            + "profiles \(enrolledProfiles.count) (focus \(focusedProfileID ?? "none"), "
            + "dormant \(dormant.count))"
    }

    // MARK: - Control socket

    /// Every verb both hosts answer alike; the two process-lifecycle verbs
    /// go to the owner's closures and are refused when none is installed.
    public func handle(_ command: ControlCommand) async -> ControlReply {
        guard !isShutDown else { return ControlReply(ok: false, message: "host shut down") }
        switch command {
        case .status:
            return ControlReply(ok: true, message: statusSummary)
        case .refresh:
            guard let engine = focusedEngine else {
                return ControlReply(ok: false, message: "no engine for the focused profile")
            }
            engine.refresh(.manual)
            return ControlReply(ok: true, message: "refresh requested (gate may coalesce)")
        case .refreshProfile(let id):
            guard let engine = engines[id] else {
                return ControlReply(ok: false, message: "no engine for profile \(id)")
            }
            engine.refresh(.manual)
            return ControlReply(ok: true, message: "refresh requested for \(id) (gate may coalesce)")
        case .setInterval(let seconds):
            setActiveInterval(seconds)
            return ControlReply(ok: true, message: "interval \(Int(activeInterval))s")
        case .setProvider(let id):
            return onSetProvider?(id)
                ?? ControlReply(ok: false, message: "not while the app hosts — use the app's Metering menu")
        case .settingsChanged:
            settingsChanged()
            return ControlReply(ok: true)
        case .refreshPricing:
            refreshPricingNow()
            return ControlReply(ok: true)
        case .scanNow:
            scanActivity(force: true)
            return ControlReply(ok: true)
        case .refreshStatus:
            refreshServiceStatus()
            return ControlReply(ok: true)
        case .checkUpdates:
            checkForUpdates()
            return ControlReply(ok: true)
        case .markNoticesSeen(let ids):
            markNoticesSeen(ids)
            return ControlReply(ok: true)
        case .dismissNotice(let id):
            let ok = dismissNotice(id: id)
            return ControlReply(ok: ok, message: ok ? nil : "not dismissable")
        case .dismissAllNotices:
            dismissAllNotices()
            return ControlReply(ok: true)
        case .focusProfile(let id):
            if let id, !profiles.contains(where: { $0.key == id && $0.isEnrolled }) {
                return ControlReply(ok: false, message: "no such profile \(id)")
            }
            setPin(id)
            return ControlReply(ok: true, message: "focus \(id ?? "follows activity")")
        case .setProfileEnabled(let id, let enabled):
            guard profiles.contains(where: { $0.key == id && $0.isEnrolled }) else {
                return ControlReply(ok: false, message: "no such profile \(id)")
            }
            setProfileEnabled(id: id, enabled: enabled)
            return ControlReply(ok: true, message: "\(id) \(enabled ? "enabled" : "disabled")")
        case .profilesChanged:
            reloadProfiles()
            return ControlReply(ok: true, message: "profiles \(enrolledProfiles.count)")
        case .shutdown:
            return onShutdown?()
                ?? ControlReply(ok: false, message: "not while the app hosts — use the app's Metering menu")
        }
    }
}
