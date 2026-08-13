import SwiftUI

/// Fixed legend palette for per-model chart coloring, tuned to read on the
/// panel's dark material. Colors are assigned by usage rank — the heaviest
/// model wears Claude's own orange — and cycle past the end.
enum ModelPalette {
    static let colors: [Color] = [
        Color(red: 0.851, green: 0.467, blue: 0.341),  // Claude orange #D97757
        Color(red: 0.420, green: 0.620, blue: 0.970),  // blue
        Color(red: 0.480, green: 0.780, blue: 0.420),  // green
        Color(red: 0.730, green: 0.550, blue: 0.950),  // purple
        Color(red: 0.900, green: 0.760, blue: 0.350),  // gold
        Color(red: 0.330, green: 0.770, blue: 0.810),  // teal
        Color(red: 0.930, green: 0.500, blue: 0.660),  // pink
        Color(red: 0.610, green: 0.650, blue: 0.710),  // slate
    ]

    /// Rank-ordered model ids → colors. Ranks come from the period's usage
    /// order, so the same map must be shared by every surface that renders
    /// models side by side (legend rows, stacked bars, drill-down ring).
    static func assignment(for models: [String]) -> [String: Color] {
        Dictionary(uniqueKeysWithValues: models.enumerated().map { index, model in
            (model, colors[index % colors.count])
        })
    }
}
