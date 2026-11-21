import Foundation
import Testing

@testable import UsageCore

/// The auto-install convergence rules (spec §10 re-amendment 2026-08-16).
/// The imperative shell (launchctl, plist writes) stays untested like the
/// rest of the process-spawning seams; everything decision-shaped is here.
struct LaunchAgentInstallerTests {
    private let binary = URL(fileURLWithPath: "/Applications/AgentUsage.app/Contents/MacOS/usaged")

    // MARK: - Plist shape

    @Test func plistCarriesTheAgentContract() throws {
        let data = try LaunchAgentInstaller.plistData(binary: binary)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        #expect(plist["Label"] as? String == AppIdentity.daemonLabel)
        #expect(plist["ProgramArguments"] as? [String] == [binary.path])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 10)
        // Background clamped every thread to priority 4 and starved the
        // daemon for minutes under load (2026-11-21, measured).
        #expect(plist["ProcessType"] as? String == "Interactive")
    }

    // MARK: - Plist currency (the migration of existing installs)

    @Test func samePlistInAnotherEncodingIsCurrent() throws {
        let data = try LaunchAgentInstaller.plistData(binary: binary)
        let binaryEncoded = try PropertyListSerialization.data(
            fromPropertyList: try PropertyListSerialization.propertyList(from: data, format: nil),
            format: .binary, options: 0)
        let parsed = try #require(
            try PropertyListSerialization.propertyList(from: binaryEncoded, format: nil) as? [String: Any])
        #expect(LaunchAgentInstaller.plistIsCurrent(installed: parsed, target: binary))
    }

    @Test func aBackgroundPlistIsNotCurrent() {
        var old = LaunchAgentInstaller.plistDictionary(binary: binary)
        old["ProcessType"] = "Background"
        #expect(!LaunchAgentInstaller.plistIsCurrent(installed: old, target: binary))
        #expect(!LaunchAgentInstaller.plistIsCurrent(installed: nil, target: binary))
    }

    @Test func currencyIsJudgedAgainstTheInstalledTarget() {
        // A plist aimed elsewhere is current when its content is what this
        // build would write FOR THAT target — never compared with the
        // caller's binary, or a heal would repoint through the back door.
        let elsewhere = URL(fileURLWithPath: "/somewhere/else/usaged")
        let installed = LaunchAgentInstaller.plistDictionary(binary: elsewhere)
        #expect(LaunchAgentInstaller.plistIsCurrent(installed: installed, target: elsewhere))
        #expect(!LaunchAgentInstaller.plistIsCurrent(installed: installed, target: binary))
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
        currentVersion: String = "0.70.0",
        intent: LaunchAgentInstaller.EnsureIntent = .claim,
        leaseHeld: Bool = false,
        plistCurrent: Bool = true,
        launchdPID: Int32? = nil,
        marker: DaemonMarker? = nil,
        targetBuild: String? = nil,
        loadedMatchesPlist: Bool = true,
        loadedRunsTarget: Bool = true
    ) -> LaunchAgentInstaller.EnsureAction {
        LaunchAgentInstaller.ensureAction(
            allowed: allowed,
            resolvedBinary: resolvedBinary,
            installedTarget: installedTarget,
            targetExists: targetExists,
            loaded: loaded,
            publishedHost: publishedHost,
            publishedVersion: publishedVersion,
            currentVersion: currentVersion,
            intent: intent,
            leaseHeld: leaseHeld,
            plistCurrent: plistCurrent,
            launchdPID: launchdPID,
            marker: marker,
            targetBuild: targetBuild,
            loadedMatchesPlist: loadedMatchesPlist,
            loadedRunsTarget: loadedRunsTarget)
    }

    /// A healthy, loaded, owned agent — the base every build-identity row
    /// varies one fact of.
    private func loadedOwned(
        intent: LaunchAgentInstaller.EnsureIntent = .claim, launchdPID: Int32? = 4242,
        marker: DaemonMarker?, targetBuild: String?
    ) -> LaunchAgentInstaller.EnsureAction {
        action(
            resolvedBinary: binary, installedTarget: binary, targetExists: true, loaded: true,
            publishedHost: "daemon", publishedVersion: "0.70.0", intent: intent,
            launchdPID: launchdPID, marker: marker, targetBuild: targetBuild)
    }

    // MARK: - Claim vs heal (2026-11-21)

    @Test func aHealNeverTouchesALiveHost() {
        #expect(
            action(
                resolvedBinary: binary, installedTarget: nil, intent: .heal, leaseHeld: true)
                == .none(.hostAlive))
        // A claim (this bundle's own launch) still converges.
        #expect(
            action(resolvedBinary: binary, installedTarget: nil, intent: .claim, leaseHeld: true)
                == .install)
    }

    @Test func aHealAdoptsAnExistingTargetInsteadOfRepointing() {
        let elsewhere = URL(fileURLWithPath: "/somewhere/else/usaged")
        #expect(
            action(
                resolvedBinary: binary, installedTarget: elsewhere, targetExists: true,
                loaded: true, intent: .heal)
                == .none(.healthy))
        #expect(
            action(
                resolvedBinary: binary, installedTarget: elsewhere, targetExists: true,
                loaded: false, intent: .heal)
                == .bootstrap)
        // Not its plist to rewrite, either.
        #expect(
            action(
                resolvedBinary: binary, installedTarget: elsewhere, targetExists: true,
                loaded: true, intent: .heal, plistCurrent: false)
                == .none(.healthy))
    }

    @Test func aHealRepointsOnlyAMissingTarget() {
        let gone = URL(fileURLWithPath: "/deleted/worktree/usaged")
        #expect(
            action(resolvedBinary: binary, installedTarget: gone, targetExists: false, intent: .heal)
                == .install)
    }

    @Test func theOwnerUpgradesAnOutdatedPlist() {
        #expect(
            action(
                resolvedBinary: binary, installedTarget: binary, targetExists: true,
                loaded: true, plistCurrent: false)
                == .install)
        #expect(
            action(
                resolvedBinary: binary, installedTarget: binary, targetExists: true,
                loaded: true, intent: .heal, plistCurrent: false)
                == .install)
    }

    // MARK: - Build identity

    private let built = "AAAAAAAA-0000-0000-0000-000000000001"
    private let rebuilt = "AAAAAAAA-0000-0000-0000-000000000002"

    @Test func aRebuiltBinaryKicksTheRunningDaemon() {
        let marker = DaemonMarker(pid: 4242, version: "0.70.0", build: built)
        #expect(loadedOwned(marker: marker, targetBuild: rebuilt) == .kickstart)
        #expect(loadedOwned(marker: marker, targetBuild: built) == .none(.healthy))
    }

    @Test func onlyTheProcessLaunchdRunsNowSpeaksForTheAgent() {
        // Just kicked, still starved: the marker is the OLD process's.
        let stale = DaemonMarker(pid: 1111, version: "0.70.0", build: built)
        #expect(loadedOwned(launchdPID: 4242, marker: stale, targetBuild: rebuilt) == .none(.healthy))
        #expect(loadedOwned(launchdPID: nil, marker: stale, targetBuild: rebuilt) == .none(.healthy))
    }

    @Test func anUnknownBuildIsNeverAMismatch() {
        let noBuild = DaemonMarker(pid: 4242, version: "0.70.0", build: nil)
        #expect(loadedOwned(marker: noBuild, targetBuild: rebuilt) == .none(.healthy))
        let marker = DaemonMarker(pid: 4242, version: "0.70.0", build: built)
        #expect(loadedOwned(marker: marker, targetBuild: nil) == .none(.healthy))
    }

    @Test func aMarkerSupersedesTheVersionRule() {
        // Same build on disk as running: no kick, whatever the digest says.
        let marker = DaemonMarker(pid: 4242, version: "0.69.0", build: built)
        #expect(
            action(
                resolvedBinary: binary, installedTarget: binary, targetExists: true, loaded: true,
                publishedHost: "daemon", publishedVersion: "0.69.0", launchdPID: 4242,
                marker: marker, targetBuild: built)
                == .none(.healthy))
    }

    @Test func aHealKicksADaemonWhoseTargetWasRebuilt() {
        // The build rule compares the daemon with ITS target, not with the
        // caller — any face may notice the agent's own binary was rebuilt.
        let elsewhere = URL(fileURLWithPath: "/somewhere/else/usaged")
        let marker = DaemonMarker(pid: 4242, version: "0.70.0", build: built)
        #expect(
            action(
                resolvedBinary: binary, installedTarget: elsewhere, targetExists: true,
                loaded: true, intent: .heal, launchdPID: 4242, marker: marker, targetBuild: rebuilt)
                == .kickstart)
    }

    // MARK: - The reload race (issue #9)

    /// A scripted launchctl: each verb answers from its own queue, the last
    /// answer repeating; every call is recorded.
    private final class Script: @unchecked Sendable {
        // @unchecked: touched from one test thread only, through `run`.
        var answers: [String: [(Int32, String)]]
        var calls: [[String]] = []
        init(_ answers: [String: [(Int32, String)]]) { self.answers = answers }
        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            calls.append(arguments)
            let verb = arguments[0]
            guard var queue = answers[verb], !queue.isEmpty else { return (0, "") }
            let answer = queue.count > 1 ? queue.removeFirst() : queue[0]
            answers[verb] = queue
            return answer
        }
        func count(_ verb: String) -> Int { calls.filter { $0[0] == verb }.count }
    }

    @Test func aBootstrapRefusedMidTeardownIsRetried() {
        // launchd still lists the old instance twice, then refuses the first
        // bootstrap with 37 (2026-10-24's log) and the second with 5.
        let script = Script([
            "print": [(0, ""), (0, ""), (113, "not found")],
            "bootstrap": [(37, "Operation already in progress"), (5, "Input/output error"), (0, "")],
        ])
        var slept: [TimeInterval] = []
        let result = LaunchAgentInstaller.reload(
            plist: "/nowhere/agent.plist", runner: script.run, sleep: { slept.append($0) })
        #expect(result.status == 0)
        #expect(script.count("bootout") == 1)
        #expect(script.count("print") == 3)
        #expect(script.count("bootstrap") == 3)
        #expect(slept.reduce(0, +) < 2)
    }

    @Test func aBootstrapThatNeverRecoversFailsWithLaunchdsWords() {
        let script = Script(["print": [(113, "")], "bootstrap": [(5, "Input/output error")]])
        var slept: TimeInterval = 0
        let result = LaunchAgentInstaller.reload(
            plist: "/nowhere/agent.plist", runner: script.run, sleep: { slept += $0 })
        #expect(result.status == 5)
        #expect(result.output == "Input/output error")
        #expect(script.count("bootstrap") == LaunchAgentInstaller.bootstrapRetryDelays.count + 1)
        #expect(slept <= LaunchAgentInstaller.bootstrapRetryDelays.reduce(0, +))
    }

    @Test func aPermanentRefusalIsNotRetried() {
        let script = Script(["print": [(113, "")], "bootstrap": [(1, "bad plist")]])
        let result = LaunchAgentInstaller.reload(
            plist: "/nowhere/agent.plist", runner: script.run, sleep: { _ in })
        #expect(result.status == 1)
        #expect(script.count("bootstrap") == 1)
    }

    @Test func theTeardownWaitIsBounded() {
        // A service that never leaves: give up waiting inside the budget.
        let script = Script(["print": [(0, "")], "bootstrap": [(0, "")]])
        var slept: TimeInterval = 0
        _ = LaunchAgentInstaller.reload(
            plist: "/nowhere/agent.plist", runner: script.run, sleep: { slept += $0 })
        #expect(slept <= LaunchAgentInstaller.leaveDomainBudget + 0.11)
    }

    @Test func nothingLoadedMeansNoWait() {
        let script = Script([
            "bootout": [(3, "No such process")], "print": [(113, "not found")], "bootstrap": [(0, "")],
        ])
        var slept: [TimeInterval] = []
        _ = LaunchAgentInstaller.reload(
            plist: "/nowhere/agent.plist", runner: script.run, sleep: { slept.append($0) })
        #expect(slept.isEmpty)
        #expect(script.count("bootstrap") == 1)
    }

    @Test func aTeardownStillListedIsWaitedOutWhateverBootoutSaid() {
        // A teardown in progress can answer non-zero; launchd still lists it.
        let script = Script([
            "bootout": [(36, "Operation now in progress")],
            "print": [(0, ""), (0, ""), (113, "not found")],
            "bootstrap": [(0, "")],
        ])
        var slept: [TimeInterval] = []
        let result = LaunchAgentInstaller.reload(
            plist: "/nowhere/agent.plist", runner: script.run, sleep: { slept.append($0) })
        #expect(result.status == 0)
        #expect(slept == [0.1, 0.1])
        #expect(script.calls.last?.first == "bootstrap")
    }

    // MARK: - launchctl print

    @Test func theJobLineGivesStateAndPid() {
        let output = [
            "gui/501/io.github.avihut.usaged = {",
            "\tactive count = 1",
            "\tstate = running",
            "\tprogram = /x/usaged",
            "\tpid = 4242",
            "}",
        ].joined(separator: "\n")
        let job = LaunchAgentInstaller.parseJob(output)
        #expect(job.state == "running")
        #expect(job.pid == 4242)
        let idle = LaunchAgentInstaller.parseJob("\tstate = not running\n")
        #expect(idle.state == "not running")
        #expect(idle.pid == nil)
        #expect(idle.program == nil && idle.spawnType == nil)
    }

    @Test func theLoadedProgramAndSpawnTypeAreRead() {
        let output = [
            "gui/501/io.github.avihut.usaged = {",
            "\tstate = running",
            "\tprogram = /x/usaged",
            "\tpid = 4242",
            "\tspawn type = background (5)",
            "\tjetsam coalition = {",
            "\t\tstate = active",
            "\t}",
            "}",
        ].joined(separator: "\n")
        let job = LaunchAgentInstaller.parseJob(output)
        #expect(job.state == "running")
        #expect(job.program == "/x/usaged")
        #expect(job.spawnType == "background")
        let target = URL(fileURLWithPath: "/x/usaged")
        // Loaded as Background while the plist says Interactive: not current.
        #expect(!LaunchAgentInstaller.loadedMatches(job, target: target))
        let applied = LaunchAgentInstaller.parseJob(output.replacingOccurrences(
            of: "background (5)", with: "interactive (4)"))
        #expect(LaunchAgentInstaller.loadedMatches(applied, target: target))
        #expect(!LaunchAgentInstaller.loadedMatches(applied, target: URL(fileURLWithPath: "/y/usaged")))
        // A format that drops both fields is unknown, never a reason to act.
        #expect(LaunchAgentInstaller.loadedMatches(
            LaunchAgentInstaller.parseJob("\tstate = running\n"), target: target))
    }

    @Test func aLoadedJobThatIsntThePlistIsReloadedByItsOwner() {
        // The file was rewritten but the reload failed: the old program (or
        // the old ProcessType) is what launchd runs. The owner reloads.
        #expect(action(
            resolvedBinary: binary, installedTarget: binary, targetExists: true, loaded: true,
            loadedMatchesPlist: false) == .install)
        // A heal never rewrites another build's plist for it.
        let other = URL(fileURLWithPath: "/elsewhere/usaged")
        #expect(action(
            resolvedBinary: binary, installedTarget: other, targetExists: true, loaded: true,
            intent: .heal, loadedMatchesPlist: false, loadedRunsTarget: false) == .none(.healthy))
    }

    @Test func aKickstartNeverTargetsAProgramLaunchdDoesntRun() {
        // Kicking re-runs what launchd loaded, not the plist: no loop.
        let other = URL(fileURLWithPath: "/elsewhere/usaged")
        #expect(action(
            resolvedBinary: binary, installedTarget: other, targetExists: true, loaded: true,
            intent: .heal, launchdPID: 7, marker: DaemonMarker(pid: 7, version: "1", build: "A"),
            targetBuild: "B", loadedRunsTarget: false) == .none(.healthy))
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
