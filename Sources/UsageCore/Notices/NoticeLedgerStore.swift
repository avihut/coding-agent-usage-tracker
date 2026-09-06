import Foundation

/// The ONE writer of a provider's `notices.json` once several engines share
/// it (multi-account metering): each profile's engine files its own resets
/// and the provider services file the outages, all through this store, so
/// no two value copies of the ledger ever race the file. Every mutation
/// goes through `mutate`, which reports whether the ledger changed and
/// tells the host (`onChange`) so a republish can follow — the digest is
/// composed from `pending` and `notices`, never from a private copy.
@MainActor
public final class NoticeLedgerStore {
    public private(set) var ledger: NoticeLedger
    /// Fired after a mutation that changed the ledger.
    public var onChange: (@MainActor () -> Void)?

    public init(ledger: NoticeLedger) {
        self.ledger = ledger
    }

    public convenience init(directory: URL) {
        self.init(ledger: NoticeLedger(directory: directory))
    }

    public var notices: [Notice] { ledger.notices }
    public var pending: [Notice] { ledger.pending }

    /// Runs one edit against the ledger. `body` returns whether it changed
    /// anything (the ledger's own mutators all report this); a change
    /// notifies `onChange`.
    @discardableResult
    public func mutate(_ body: (inout NoticeLedger) -> Bool) -> Bool {
        let changed = body(&ledger)
        if changed { onChange?() }
        return changed
    }
}
