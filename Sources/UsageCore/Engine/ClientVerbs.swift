import Foundation

/// What a per-profile client face sends over the socket, chosen by the
/// host it is talking to: a pre-0.96 daemon knows only `refresh` (which
/// refreshes its one engine), a profile-aware host takes `refreshProfile`
/// so a face for the personal account never pokes the work one.
public enum ClientVerbs {
    public static func refresh(profileID: String, legacyHost: Bool) -> ControlCommand {
        legacyHost ? .refresh : .refreshProfile(id: profileID)
    }
}
