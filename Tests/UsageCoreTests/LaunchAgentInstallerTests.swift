import Foundation
import Testing

@testable import UsageCore

/// The auto-install convergence rules (spec §10 re-amendment 2026-08-16).
/// The imperative shell (launchctl, plist writes) stays untested like the
/// rest of the process-spawning seams; everything decision-shaped is here.
struct LaunchAgentInstallerTests {
    private let binary = URL(fileURLWithPath: "/Applications/ClaudeUsage.app/Contents/MacOS/usaged")

    // MARK: - Plist shape

    @Test func plistCarriesTheAgentContract() throws {
        let data = try LaunchAgentInstaller.plistData(binary: binary)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        #expect(plist["Label"] as? String == "com.avihu.usaged")
        #expect(plist["ProgramArguments"] as? [String] == [binary.path])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 10)
        #expect(plist["ProcessType"] as? String == "Background")
    }

    @Test func targetRoundTripsThroughThePlist() throws {
        let data = try LaunchAgentInstaller.plistData(binary: binary)
        #expect(LaunchAgentInstaller.target(inPlist: data) == binary)
    }

    // MARK: - Sticky opt-out flag

    @Test func autoInstallDefaultsToAllowed() throws {
        let suite = "installer-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(LaunchAgentInstaller.autoInstallAllowed(defaults: defaults))
        LaunchAgentInstaller.setAutoInstall(false, defaults: defaults)
        #expect(!LaunchAgentInstaller.autoInstallAllowed(defaults: defaults))
        LaunchAgentInstaller.setAutoInstall(true, defaults: defaults)
        #expect(LaunchAgentInstaller.autoInstallAllowed(defaults: defaults))
    }

    // MARK: - Convergence table

    private func action(
        allowed: Bool = true,
        resolvedBinary: URL? = nil,
        installedTarget: URL? = nil,
        targetExists: Bool = false,
        loaded: Bool = false,
        publishedHost: String? = nil,
        publishedVersion: String? = nil,
        currentVersion: String = "0.70.0"
    ) -> LaunchAgentInstaller.EnsureAction {
        LaunchAgentInstaller.ensureAction(
            allowed: allowed,
            resolvedBinary: resolvedBinary,
            installedTarget: installedTarget,
            targetExists: targetExists,
            loaded: loaded,
            publishedHost: publishedHost,
            publishedVersion: publishedVersion,
            currentVersion: currentVersion)
    }

    @Test func optOutBeatsEverything() {
        #expect(
            action(allowed: false, resolvedBinary: binary, loaded: false)
                == .none(.disabled))
    }

    @Test func noBinaryMeansNothingToInstall() {
        #expect(action(resolvedBinary: nil) == .none(.binaryNotFound))
    }

    @Test func absentPlistInstalls() {
        #expect(action(resolvedBinary: binary, installedTarget: nil) == .install)
    }

    @Test func deadTargetReinstalls() {
        #expect(
            action(resolvedBinary: binary, installedTarget: binary, targetExists: false)
                == .install)
    }

    @Test func misaimedPlistRepoints() {
        let elsewhere = URL(fileURLWithPath: "/somewhere/else/usaged")
        #expect(
            action(resolvedBinary: binary, installedTarget: elsewhere, targetExists: true)
                == .install)
    }

    @Test func installedButUnloadedBootstraps() {
        #expect(
            action(
                resolvedBinary: binary, installedTarget: binary, targetExists: true,
                loaded: false)
                == .bootstrap)
    }

    @Test func staleDaemonVersionKickstarts() {
        #expect(
            action(
                resolvedBinary: binary, installedTarget: binary, targetExists: true,
                loaded: true, publishedHost: "daemon", publishedVersion: "0.69.0")
                == .kickstart)
    }

    @Test func appHostedDigestNeverJustifiesAKick() {
        // While the app publishes, a loaded daemon idles on the lease and
        // its running version is unknowable — leave it be.
        #expect(
            action(
                resolvedBinary: binary, installedTarget: binary, targetExists: true,
                loaded: true, publishedHost: "app", publishedVersion: "0.69.0")
                == .none(.healthy))
    }

    @Test func currentHealthyAgentIsLeftAlone() {
        #expect(
            action(
                resolvedBinary: binary, installedTarget: binary, targetExists: true,
                loaded: true, publishedHost: "daemon", publishedVersion: "0.70.0")
                == .none(.healthy))
    }
}
