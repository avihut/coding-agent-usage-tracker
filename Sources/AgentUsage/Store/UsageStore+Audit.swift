import UsageCore

extension UsageStore {
    /// The meter the audit surfaces read at this rank (0 session, 1 weekly):
    /// its label keys the samples/ledger; a meter without a known window
    /// length can't place cliffs, so it offers no audit.
    func auditMeter(rank: Int) -> AuditMeterInfo? {
        guard let meter = state.snapshot?.meters.first(where: { $0.rank == rank }),
              let window = meter.limitWindow
        else { return nil }
        return AuditMeterInfo(label: meter.label, window: window)
    }
}
