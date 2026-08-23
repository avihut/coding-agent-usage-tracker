import Foundation
import Testing

@testable import UsageCore

/// The one predicate every window-roll detector reads. The jitter values
/// here are the measured field range: a fortnight of weekly stamps spanned
/// ±0.5s around their true boundary without two ever matching.
@Suite("ResetStamp")
struct ResetStampTests {
    private let anchor = Date(timeIntervalSince1970: 1_787_000_000)

    @Test("sub-second jitter is the same window")
    func jitter() {
        #expect(!ResetStamp.moved(anchor.addingTimeInterval(-0.492), anchor.addingTimeInterval(0.437)))
        #expect(!ResetStamp.moved(anchor, anchor))
    }

    @Test("a shift of hours is a roll, in either direction")
    func realRoll() {
        #expect(ResetStamp.moved(anchor, anchor.addingTimeInterval(5 * 3600)))
        #expect(ResetStamp.moved(anchor.addingTimeInterval(7 * 86400), anchor))
    }

    @Test("a stamp appearing or vanishing is a change; two absences are not")
    func optionals() {
        #expect(ResetStamp.moved(nil, anchor))
        #expect(ResetStamp.moved(anchor, nil))
        #expect(!ResetStamp.moved(nil as Date?, nil as Date?))
        #expect(!ResetStamp.moved(anchor as Date?, anchor.addingTimeInterval(0.9) as Date?))
    }

    @Test("rolledForward needs a later window — jitter and backward moves don't close")
    func forward() {
        #expect(!ResetStamp.rolledForward(from: anchor, to: anchor.addingTimeInterval(0.9)))
        #expect(!ResetStamp.rolledForward(from: anchor, to: anchor.addingTimeInterval(-3600)))
        #expect(ResetStamp.rolledForward(from: anchor, to: anchor.addingTimeInterval(5 * 3600)))
    }
}
