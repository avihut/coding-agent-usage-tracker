import Foundation
import Security

/// "Signed by whoever signed the app I already am."
///
/// `codesign --verify` proves a bundle's signature is INTACT, never WHOSE it
/// is — an ad-hoc bundle, or one signed by anybody's certificate, passes. For
/// an updater that is the whole question: the download replaces the running
/// app. So the installed bundle's own DESIGNATED REQUIREMENT (the rule macOS
/// itself uses to decide "is this the same app" — for a certificate-signed
/// build, the identifier plus the signing certificate's chain) is read, and
/// the candidate must satisfy it. No identity is named anywhere in the repo;
/// the pin is whatever this install already is.
///
/// Fails closed by construction: an AD-HOC build's requirement is its own
/// code hash, which no other build satisfies — an ad-hoc install cannot
/// vouch for a successor and never self-updates. A changed bundle identifier
/// or signing certificate fails the same way, and the way through is a
/// rebuild from source, never a looser check.
public enum SignerPin {
    public enum Failure: Error, Equatable {
        /// The installed bundle has no readable requirement (unsigned, or
        /// the path isn't code).
        case installedUnreadable(OSStatus)
        /// The candidate isn't code at all.
        case candidateUnreadable(OSStatus)
        /// The candidate is validly signed by someone else, tampered with,
        /// or unsigned — all one answer: not ours.
        case notSatisfied(OSStatus)
    }

    /// Throws unless `candidate` satisfies `installed`'s designated
    /// requirement, nested code and every architecture included.
    public static func verify(candidate: URL, against installed: URL) throws(Failure) {
        let requirement = try designatedRequirement(of: installed)
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(candidate as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw .candidateUnreadable(created) }
        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw .notSatisfied(status) }
    }

    /// The requirement in its text form — for a log line or an error, never
    /// for comparison.
    public static func requirementText(of bundle: URL) -> String? {
        guard let requirement = try? designatedRequirement(of: bundle) else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static func designatedRequirement(of bundle: URL) throws(Failure) -> SecRequirement {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw .installedUnreadable(created) }
        var requirement: SecRequirement?
        let copied = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard copied == errSecSuccess, let requirement else { throw .installedUnreadable(copied) }
        return requirement
    }
}
