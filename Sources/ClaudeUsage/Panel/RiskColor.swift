import SwiftUI

/// The continuous exhaustion-risk ramp: nil while the forecast is clean,
/// pure yellow where the projection touches the warning threshold, sliding
/// linearly to pure red where the limit is spent. Every risk surface —
/// meter bars, captions, the chart's projection curve and axis label —
/// blends through this one function.
func riskColor(severity: Double) -> Color? {
    guard severity > 0 else { return nil }
    return Color.yellow.mix(with: .red, by: severity)
}
