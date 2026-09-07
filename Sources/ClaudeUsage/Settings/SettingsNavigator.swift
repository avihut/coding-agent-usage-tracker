import Observation
import SwiftUI

/// Where inside a pane a request should land — the consume-once idiom
/// `SessionsNavigator` uses for the sessions sidebar. A click on a
/// "Claude Code account found" notice has to open Settings AND put the
/// Accounts card in front of the person, which a pane selection alone
/// can't express.
enum SettingsLanding: String, Identifiable {
    case accounts

    var id: String { rawValue }
}

/// One request to the open settings window: which pane, and what to scroll
/// to once it renders. Consumed by the pane, so a second landing on the
/// same card works.
@MainActor
@Observable
final class SettingsNavigator {
    /// The pane a request wants; nil once applied.
    private(set) var requestedSection: SettingsSection?
    /// The anchor a request wants scrolled into view; nil once applied.
    private(set) var landing: SettingsLanding?

    func request(section: SettingsSection, landing: SettingsLanding? = nil) {
        requestedSection = section
        self.landing = landing
    }

    func consumeSection() -> SettingsSection? {
        defer { requestedSection = nil }
        return requestedSection
    }

    func consumeLanding() -> SettingsLanding? {
        defer { landing = nil }
        return landing
    }
}
