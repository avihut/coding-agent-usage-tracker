import Foundation
import UsageCore

/// Milestone-1 debug tool: reads the token through the credential chain, hits
/// the usage endpoint once, prints the raw JSON body to stdout. Diagnostics go
/// to stderr and never contain the token.
///
/// `usage-cli sessions [--provider <id>]` instead prints the session index —
/// the sessions browser's data layer, verifiable headless. It READS the app's
/// warm scan cache but never writes it (`persistCache: false`): the app stays
/// the sole cache writer, so a CLI run can't race or clobber a live scan.
@main
struct UsageCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("sessions") {
            runSessions(providerID: value(after: "--provider", in: arguments))
            return
        }

        let credential: Credential
        do {
            credential = try CredentialChain.standard.readCredential()
        } catch let error as CredentialError {
            fail(credentialError: error)
        } catch {
            die("unexpected credential error: \(type(of: error))", code: 1)
        }

        note("credentials: \(credential.sourceName)")

        do {
            let body = try await UsageClient().fetchRawUsage(accessToken: credential.accessToken)
            note("HTTP 200, \(body.count) bytes")
            FileHandle.standardOutput.write(body)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let error as UsageClientError {
            fail(clientError: error)
        } catch {
            die("unexpected client error: \(type(of: error))", code: 1)
        }
    }

    private static func fail(credentialError: CredentialError) -> Never {
        switch credentialError {
        case .notFound:
            die("no Claude Code credentials found (checked ~/.claude/.credentials.json and the login Keychain)", code: 2)
        case .accessDenied(let status):
            die("keychain access denied (OSStatus \(status)) — approve the Keychain prompt, or click \"Always Allow\" to stop future prompts", code: 3)
        case .unreadable(let reason):
            die("credentials unreadable: \(reason)", code: 7)
        }
    }

    private static func fail(clientError: UsageClientError) -> Never {
        switch clientError {
        case .signInExpired:
            die("sign-in expired (401/403) — open Claude Code to refresh the token", code: 4)
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { " (Retry-After \(Int($0))s)" } ?? ""
            die("rate limited (429)\(wait) — try again later", code: 9)
        case .http(let code):
            die("unexpected HTTP \(code) from usage endpoint", code: 5)
        case .network(let urlError):
            die("network failure: \(urlError.code)", code: 6)
        case .schema:
            die("unexpected API response — the undocumented schema may have changed", code: 8)
        case .noLocalData:
            die("no local session files found for this provider", code: 10)
        }
    }

    // MARK: - sessions mode

    private static func runSessions(providerID: String?) {
        // The registry's persisted pick; "auto" means no explicit choice.
        let stored = UserDefaults.standard.string(forKey: "activeProviderID")
        let chosen = providerID ?? (stored == "auto" ? nil : stored) ?? "claude"
        // A bare executable has no bundle identity — same fallback the app
        // uses, so both read the same scoped cache.
        let bundleID = "com.avihu.ClaudeUsage"
        let support = StorageScope.supportDirectory(bundleID: bundleID, providerID: chosen)

        guard chosen == "claude" else {
            die("sessions are not wired for '\(chosen)' in the CLI yet", code: 11)
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        let scanner = TranscriptScanner(root: root, cacheDirectory: support)
        let scan = scanner.scan(persistCache: false)
        guard !scan.sessions.isEmpty else {
            note("no sessions found under ~/.claude/projects")
            return
        }

        let provider = ClaudeProvider()
        let pricing = PricingService(
            cacheDirectory: support, fallback: provider.bundledRates,
            selector: provider.pricingSelector
        ).current()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        note("\(scan.sessions.count) sessions (\(provider.agentName))")
        for session in scan.sessions {
            var dollars = 0.0
            var unpriced = 0
            for (model, tally) in session.models {
                if let rates = pricing.rates(for: model) {
                    dollars += rates.dollars(for: tally)
                } else {
                    unpriced += 1
                }
            }
            let cost = unpriced > 0 && dollars == 0
                ? "      —" : String(format: "%8.2f", dollars)
            let badge = session.kind == .background ? " [bg]" : "     "
            let line = "\(formatter.string(from: session.end))  $\(cost)  "
                + "\(String(format: "%5d", session.apiCalls)) calls  "
                + "\(TokenFormat.compact(session.totalTokens).padding(toLength: 7, withPad: " ", startingAt: 0))"
                + "\(badge)  \(session.title)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("[usage-cli] \(message)\n".utf8))
    }

    private static func die(_ message: String, code: Int32) -> Never {
        note(message)
        exit(code)
    }
}
