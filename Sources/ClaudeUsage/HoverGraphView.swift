import Charts
import SwiftUI
import UsageCore

/// The iStat-style hover popover: recent sampled percentages per limit.
struct HoverGraphView: View {
    let samples: [UsageSample]

    private static let window: TimeInterval = 6 * 3600

    private struct Point: Identifiable {
        let id: String
        let label: String
        let t: Date
        let percent: Int
    }

    private var points: [Point] {
        let cutoff = Date().addingTimeInterval(-Self.window)
        return samples
            .filter { $0.t >= cutoff }
            .flatMap { sample in
                sample.percents.map { label, percent in
                    Point(
                        id: "\(label)|\(sample.t.timeIntervalSince1970)",
                        label: label, t: sample.t, percent: percent)
                }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage — last 6h")
                .font(.caption)
                .foregroundStyle(.secondary)
            if points.count < 4 {
                Text("Collecting samples — the graph fills in as refreshes accumulate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 260, height: 80)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.t),
                        y: .value("Percent", point.percent)
                    )
                    .foregroundStyle(by: .value("Limit", point.label))
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartLegend(position: .bottom, spacing: 4)
                .frame(width: 280, height: 140)
            }
        }
        .padding(12)
    }
}
