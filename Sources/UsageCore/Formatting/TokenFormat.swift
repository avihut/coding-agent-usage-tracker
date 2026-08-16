import Foundation

/// "12.3K", "1.2M", "3B" — token counts at heatmap scale.
public enum TokenFormat {
    public static func compact(_ count: Int) -> String {
        let value = Double(count)
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return trimmed(value / 1000) + "K"
        case ..<1_000_000_000: return trimmed(value / 1_000_000) + "M"
        default: return trimmed(value / 1_000_000_000) + "B"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
