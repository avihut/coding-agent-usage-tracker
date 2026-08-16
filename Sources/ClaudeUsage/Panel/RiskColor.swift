import SwiftUI
import UsageCore

/// The exhaustion-risk ramp, as SwiftUI: a one-line wrapper over core
/// `RiskRamp`, which owns the math and the pinned endpoint colors — the
/// panel, the menu bar, and the digest all blend identically through it.
func riskColor(severity: Double) -> Color? {
    RiskRamp.color(severity: severity).map {
        Color(red: $0.red, green: $0.green, blue: $0.blue)
    }
}
